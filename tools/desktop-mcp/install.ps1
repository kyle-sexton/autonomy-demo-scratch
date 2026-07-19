#requires -Version 7
<#
.SYNOPSIS
  Install/refresh Claude Desktop MCP server config to match this repo's CC setup.

.DESCRIPTION
  Reads claude_desktop_config.json from the resolved Claude Desktop install
  location (Anthropic Desktop -3p preferred, classic Win32 fallback, vestigial
  MSIX recognized), preserves any non-MCP top-level keys (e.g. 'preferences'),
  merges in the 12 MCP server definitions that mirror our Claude Code setup,
  and writes the result back. Runs a Preflight phase first that gates the write
  on severity findings (PASS / WARN / FAIL).

  Run from any CWD inside this repo. The script resolves the repo root via
  'git rev-parse --show-toplevel' so the embedded paths stay correct on any
  clone location.

.PARAMETER WhatIf
  Print the merged config to stdout without writing. Does NOT exit on FAIL —
  dry-run mode shows the full output for inspection.

.PARAMETER NonInteractive
  Skip the WARN-confirmation prompt. Any WARN or FAIL aborts with exit code 2.
  Use in CI / unattended re-runs.

.NOTES
  Preflight gates (FAIL aborts; WARN prompts in interactive mode):
    - desktop-variant    Ambiguous variant state, or no variant installed
    - existing-config    3-state classification (ABSENT / OUR-MANAGED /
                         FOREIGN-OR-MERGED)
    - path-safety        Reparse-point detection
    - writable           Probe write to target dir (cleaned up via try/finally)
    - backup-integrity   Detect recursively-wrapped .backup files
    - smell-test         Unexpected top-level keys outside the whitelist
    - prereq-*           fnm, MCP build artifacts, .bat launchers, User env keys

  Exit codes:
    0  preflight clear (or only PASS), write succeeded (or WhatIf dry-run)
    1  preflight clear but write failed mid-flight
    2  preflight aborted (FAIL finding OR WARN in NonInteractive)

  Verification levels (the only signal proving config was loaded by Desktop is
  Tier 3 — see verify.ps1 for Tier 2 and the issue body for Tier 3 detail):
    Tier 1  config file is valid JSON                  — verified by THIS script
    Tier 2  each server's spawn command handshakes OK  — verify.ps1
    Tier 3  Desktop emits %APPDATA%\Claude\logs\mcp-server-<NAME>.log
            after a full quit+relaunch                  — manual

  After running this script (preflight + write):
    - Fully quit Claude Desktop (system tray -> Quit).
    - Relaunch.
    - Confirm Tier 3 by inspecting per-server logs (see paths printed at end).

  Reverse: jq 'del(.mcpServers)' <config>
  (Or restore from <config>.backup written by this script on first run.)
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive operator install tool; colored Write-Host output is the intended UX surface.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidLongLines', '', Justification = 'Diagnostic messages and Windows paths exceed 120 chars; breaking them harms readability.')]
param(
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Marker written into every produced config. Future runs use this to discriminate
# OUR-MANAGED (safe to replace mcpServers wholesale) from FOREIGN-OR-MERGED
# (came from another tool — surface to user). Matches either path separator
# for cross-shell tolerance.
$Script:ManagedByMarker = 'tools/desktop-mcp/install.ps1'

# Preflight findings accumulator. Each entry: { Severity, Check, Message, Remediation }.
$Script:Findings = [System.Collections.Generic.List[psobject]]::new()
# Existing-config classification — set by Invoke-Preflight, consumed by the write phase.
$Script:ExistingClass = 'UNKNOWN'

# Severity → console color, used by New-PreflightFinding.
$Script:SeverityColors = @{
    PASS = 'Green'
    WARN = 'Yellow'
    FAIL = 'Red'
}

# ---------------------------------------------------------------- repo + target paths
$RepoRoot = (& git rev-parse --show-toplevel) -replace '/', '\'
if (-not $RepoRoot) { throw 'git rev-parse failed; run this script from inside the repo' }

# Claude Desktop ships in three Windows variants, each with its OWN config path:
#
#   1. "Anthropic Desktop -3p" (the current Anthropic-branded MSIX app, v1.7196+):
#      %LOCALAPPDATA%\Claude-3p\claude_desktop_config.json
#      Determined by reading the asar binary's config-path logic:
#        $9t = `Claude${L_A}` with L_A = "-3p"
#        CJe() returns path.join(process.env.LOCALAPPDATA, $9t) on win32
#
#   2. "Classic Claude Desktop" (older Electron app, Win32 installer, v0.x):
#      %APPDATA%\Claude\claude_desktop_config.json
#
#   3. (Vestigial) MSIX-virtualized classic-Claude path:
#      %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\claude_desktop_config.json
#      This was a red-herring path early in the desktop-mcp work — the new Anthropic
#      Desktop creates an MSIX package dir but does NOT read this location. Kept here
#      as a recognized-but-deprecated discriminator.
#
# We prefer variant 1 (current Anthropic Desktop) whenever its parent dir exists,
# since that's the actively-developed surface. Falls back to (2) when (1) is absent.

function Resolve-ClaudeDesktopConfigPath {
    $candidates = [System.Collections.Generic.List[psobject]]::new()
    # 1. Current Anthropic Desktop "-3p"
    $candidates.Add([pscustomobject]@{
            Kind         = 'AnthropicDesktop-3p'
            Path         = Join-Path $env:LOCALAPPDATA 'Claude-3p\claude_desktop_config.json'
            ParentExists = Test-Path (Join-Path $env:LOCALAPPDATA 'Claude-3p')
        })
    # 2. Classic Win32 install
    $candidates.Add([pscustomobject]@{
            Kind         = 'ClassicWin32'
            Path         = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
            ParentExists = Test-Path (Join-Path $env:APPDATA 'Claude')
        })
    # 3. Vestigial MSIX-virtualized classic path (recognized; NOT preferred)
    Get-ChildItem -Path "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'
        $candidates.Add([pscustomobject]@{
                Kind         = 'VestigialMSIX'
                Path         = $p
                ParentExists = Test-Path (Split-Path $p -Parent)
            })
    }

    # Prefer the canonical AnthropicDesktop-3p path whenever its parent dir exists.
    # This is the surface Claude Desktop v1.7196+ actually reads.
    $primary = $candidates | Where-Object { $_.Kind -eq 'AnthropicDesktop-3p' -and $_.ParentExists } | Select-Object -First 1
    if ($primary) { return $primary }

    # Otherwise prefer the variant that already has a config file present.
    $existing = $candidates | Where-Object { Test-Path $_.Path } | Select-Object -First 1
    if ($existing) { return $existing }

    # Last resort: the AnthropicDesktop-3p path even if dir doesn't exist (it'll be created).
    return $candidates | Where-Object { $_.Kind -eq 'AnthropicDesktop-3p' } | Select-Object -First 1
}

# ---------------------------------------------------------------- preflight helpers

function New-PreflightFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string]$Severity,
        [Parameter(Mandatory)] [string]$Check,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Remediation = ''
    )
    $finding = [pscustomobject]@{
        Severity    = $Severity
        Check       = $Check
        Message     = $Message
        Remediation = $Remediation
    }
    $Script:Findings.Add($finding)

    Write-Host ('  [{0}] {1}: ' -f $Severity, $Check) -ForegroundColor $Script:SeverityColors[$Severity] -NoNewline
    Write-Host $Message
    if ($Remediation) {
        Write-Host "       -> $Remediation" -ForegroundColor DarkGray
    }
}

function Get-AsarVariantSuffix {
    # Deep verification: extract the L_A variant suffix from Claude Desktop's
    # app.asar bundle. The asar contains minified JS where the config path is
    # built as `Claude${L_A}` (RESEARCH.md "TDD path that landed us here" row 5).
    # Returns:
    #   @{ Status='ok'; Suffix=<value>; PackageVersion=<full name>; InstallLocation=<path>; AsarPath=<path> }
    #   @{ Status='no-package' }                  — no MSIX Claude package installed
    #   @{ Status='no-asar'; PackageVersion=... } — package found but app.asar absent at expected sub-path
    #   @{ Status='unreadable'; Reason=<msg> }    — asar exists but ACL/lock prevents read
    #   @{ Status='no-match'; PackageVersion=... } — asar read but L_A= pattern not found (minifier changed names)
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # Discover MSIX Claude install location without Get-AppxPackage. The Appx
    # module fires Set-Alias side effects on auto-load, which -WhatIf intercepts
    # with noisy "What if: Set Alias" output. Filesystem scan avoids the module
    # entirely and works the same in WhatIf + real-run paths.
    $pkgDir = Get-ChildItem -Path 'C:\Program Files\WindowsApps' -Directory -Filter 'Claude_*_x64_*' -ErrorAction SilentlyContinue |
        Sort-Object { [version](($_.Name -replace '^Claude_([0-9.]+)_.*$', '$1')) } -Descending -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $pkgDir) { return @{ Status = 'no-package' } }

    $candidateAsar = @(
        (Join-Path $pkgDir.FullName 'app\resources\app.asar'),
        (Join-Path $pkgDir.FullName 'resources\app.asar')
    )
    $asar = $candidateAsar | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $asar) { return @{ Status = 'no-asar'; PackageVersion = $pkgDir.Name } }
    # Shim a pkg-shaped object for downstream return shape
    $pkg = [pscustomobject]@{ PackageFullName = $pkgDir.Name; InstallLocation = $pkgDir.FullName }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($asar)
    } catch {
        return @{ Status = 'unreadable'; Reason = $_.Exception.Message; PackageVersion = $pkg.PackageFullName }
    }
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    # Quoted single-char variable name with uppercase letters (matches minified `L_A="-3p"` shape).
    # Tolerates rotation of the variable identifier across builds — the assignment shape is stable.
    $m = [regex]::Match($text, '\b[A-Za-z_][A-Za-z_0-9]{0,4}\s*=\s*"(-[A-Za-z0-9]{1,8})"[,;]\s*[A-Za-z_$][^=]{0,40}=\s*`Claude\$\{')
    if (-not $m.Success) {
        # Fallback: search for any quoted variant suffix that appears adjacent to `Claude${
        $m = [regex]::Match($text, '"(-[A-Za-z0-9]{1,8})".{0,80}`Claude\$\{')
    }
    if ($m.Success) {
        return @{ Status = 'ok'; Suffix = $m.Groups[1].Value; PackageVersion = $pkg.PackageFullName; AsarPath = $asar }
    }
    return @{ Status = 'no-match'; PackageVersion = $pkg.PackageFullName; AsarPath = $asar }
}

function Get-AnthropicDocsFreshness {
    # Active drift detection: fetch the canonical MCP spec page for Desktop
    # client setup. modelcontextprotocol.io is the open-standard primary source
    # (per RESEARCH.md §3 sources cited). support.claude.com renders client-side
    # via Intercom SPA — raw HTML body is empty, breaks plain HTTP probes.
    # Cannot catch the asar-derived Claude-3p path drift because Anthropic
    # hasn't documented it publicly — that's what Get-AsarVariantSuffix is for.
    # Returns: @{ Status='ok'|'fetch-failed'|'unexpected-content'; Url=...; Reason=... }
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $url = 'https://modelcontextprotocol.io/docs/develop/connect-local-servers'
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    } catch {
        return @{ Status = 'fetch-failed'; Url = $url; Reason = $_.Exception.Message }
    }
    if ($resp.StatusCode -ne 200) {
        return @{ Status = 'fetch-failed'; Url = $url; Reason = "HTTP $($resp.StatusCode)" }
    }
    $body = $resp.Content
    if ($body -notmatch 'claude_desktop_config') {
        return @{ Status = 'unexpected-content'; Url = $url; Reason = "page body does not mention 'claude_desktop_config'" }
    }
    return @{ Status = 'ok'; Url = $url }
}

function Get-ConnectorOverlap {
    # Best-effort filesystem inspection for Anthropic Connector / built-in MCP
    # state that could conflict with what this script installs. Desktop's
    # Connector list is stored in app-internal state (no documented filesystem
    # path); the only durable signal is which of our servers Desktop ALSO ships
    # as a built-in Connector — currently confirmed: granola.
    # Returns hashtable mapping our-server-name -> conflict-description string.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$DesiredServers
    )
    # Anthropic ships a hosted Granola Connector; if user signed in to both
    # Connector AND our mcp-remote-proxied granola, requests double up.
    # Source: RESEARCH.md §1 "user signed in to BOTH during testing".
    $hostedConnectors = @{
        granola = 'Anthropic ships a hosted Granola Connector reachable via Settings -> Integrations. Running both the Connector AND the mcp-remote-proxied stdio server (this script) means two parallel granola clients sharing one OAuth identity.'
    }
    $overlap = @{}
    foreach ($k in $DesiredServers.Keys) {
        if ($hostedConnectors.ContainsKey($k)) {
            $overlap[$k] = $hostedConnectors[$k]
        }
    }
    return $overlap
}

function Invoke-Preflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject]$Resolved,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary]$DesiredServers,
        [Parameter(Mandatory)] [string]$Context7Bat,
        [Parameter(Mandatory)] [string]$RefBat,
        [Parameter(Mandatory)] [string]$GithubEventsBuild
    )

    # 1. Variant detection — enriched diagnostic for next path-mismatch incident
    $localExists = Test-Path (Join-Path $env:LOCALAPPDATA 'Claude-3p')
    $classicExists = Test-Path (Join-Path $env:APPDATA 'Claude')
    $variantMsg = "Selected variant=$($Resolved.Kind); target=$($Resolved.Path). Claude-3p dir exists=$localExists; Classic dir exists=$classicExists."
    if ($localExists -and $classicExists) {
        New-PreflightFinding -Severity 'WARN' -Check 'desktop-variant' `
            -Message "$variantMsg Both variant dirs present." `
            -Remediation 'Confirm which Desktop variant your Start Menu actually launches. If Anthropic Desktop (-3p), this script targets the right place. Uninstall the stale one to disambiguate.'
    } elseif (-not $localExists -and -not $classicExists) {
        New-PreflightFinding -Severity 'FAIL' -Check 'desktop-variant' `
            -Message "$variantMsg Neither variant dir exists." `
            -Remediation 'Install Claude Desktop first (Anthropic Desktop -3p preferred) and launch it once so it creates its app dir. Then re-run.'
    } else {
        New-PreflightFinding -Severity 'PASS' -Check 'desktop-variant' -Message $variantMsg
    }

    # 1a. Deep variant verify via asar grep — extract L_A suffix from the MSIX
    # bundle and confirm the resolved path uses the same variant.
    $asar = Get-AsarVariantSuffix
    switch ($asar.Status) {
        'ok' {
            # Expected dirname == "Claude" + suffix (e.g. "Claude-3p")
            $expectedDir = "Claude$($asar.Suffix)"
            $resolvedDir = Split-Path (Split-Path $Resolved.Path -Parent) -Leaf
            if ($resolvedDir -eq $expectedDir) {
                New-PreflightFinding -Severity 'PASS' -Check 'asar-path-verify' `
                    -Message "asar L_A='$($asar.Suffix)' → expected dir '$expectedDir' matches resolved dir '$resolvedDir'. Package: $($asar.PackageVersion)"
            } else {
                New-PreflightFinding -Severity 'FAIL' -Check 'asar-path-verify' `
                    -Message "asar-extracted variant suffix '$($asar.Suffix)' implies dir '$expectedDir', but resolved path uses '$resolvedDir'. Desktop will not read what this script writes." `
                    -Remediation "Update Resolve-ClaudeDesktopConfigPath in install.ps1 to target '%LOCALAPPDATA%\$expectedDir\claude_desktop_config.json'."
            }
        }
        'no-package' {
            New-PreflightFinding -Severity 'WARN' -Check 'asar-path-verify' `
                -Message 'No MSIX Claude package found via Get-AppxPackage. Desktop may be installed as classic Win32 (no asar verification possible there).' `
                -Remediation 'If Anthropic Desktop is installed via MSIX, ensure PowerShell can call Get-AppxPackage (run from a user shell, not SYSTEM context).'
        }
        'no-asar' {
            New-PreflightFinding -Severity 'WARN' -Check 'asar-path-verify' `
                -Message "MSIX package $($asar.PackageVersion) located but app.asar not at expected sub-path. Deep verify skipped."
        }
        'unreadable' {
            New-PreflightFinding -Severity 'WARN' -Check 'asar-path-verify' `
                -Message "MSIX package $($asar.PackageVersion) located, asar present but unreadable: $($asar.Reason). Deep verify skipped." `
                -Remediation 'Read access to WindowsApps is normally allowed for the installed user. If denied, run from a non-elevated user shell.'
        }
        'no-match' {
            New-PreflightFinding -Severity 'WARN' -Check 'asar-path-verify' `
                -Message "MSIX package $($asar.PackageVersion) located, asar read, but L_A= variant assignment pattern not found. Anthropic likely changed the minifier output." `
                -Remediation "Inspect $($asar.AsarPath) manually for the path-derivation logic (grep for 'process.env.LOCALAPPDATA'); update Get-AsarVariantSuffix regex to match the new shape."
        }
    }

    # 1b. Docs freshness — actively fetch authoritative Anthropic Desktop docs
    # URL and assert it still describes claude_desktop_config.
    $docs = Get-AnthropicDocsFreshness
    switch ($docs.Status) {
        'ok' {
            New-PreflightFinding -Severity 'PASS' -Check 'docs-freshness' `
                -Message "Anthropic Desktop docs URL reachable and references claude_desktop_config: $($docs.Url)"
        }
        'fetch-failed' {
            New-PreflightFinding -Severity 'WARN' -Check 'docs-freshness' `
                -Message "Could not fetch Anthropic Desktop docs ($($docs.Url)): $($docs.Reason)" `
                -Remediation 'Verify network connectivity. If the URL has moved, update the path in Get-AnthropicDocsFreshness.'
        }
        'unexpected-content' {
            New-PreflightFinding -Severity 'WARN' -Check 'docs-freshness' `
                -Message "Anthropic Desktop docs page fetched but missing expected content: $($docs.Reason). Page URL: $($docs.Url)" `
                -Remediation 'Re-fetch the page manually; if Anthropic restructured the article, update install.ps1 path-derivation rationale + recheck triggers.'
        }
    }

    # 2. Existing-config inspection — 3-state classification:
    #    ABSENT             no file yet
    #    OUR-MANAGED        either marker present OR all server keys match this script's set
    #                       (both are permanent valid discriminators — no transitional state)
    #    FOREIGN-OR-MERGED  marker absent AND key set diverges; surface diff to user
    if (-not (Test-Path $Resolved.Path)) {
        New-PreflightFinding -Severity 'PASS' -Check 'existing-config' `
            -Message 'No existing config at target; will create fresh.'
        $Script:ExistingClass = 'ABSENT'
        $existingConfig = $null
    } else {
        try {
            $existingConfig = Get-Content -Raw -Path $Resolved.Path | ConvertFrom-Json -AsHashtable
        } catch {
            New-PreflightFinding -Severity 'FAIL' -Check 'existing-config' `
                -Message "Existing config at $($Resolved.Path) is invalid JSON: $($_.Exception.Message)" `
                -Remediation 'Inspect manually. Restore from a .backup if present, or delete and re-run.'
            $Script:ExistingClass = 'INVALID'
            $existingConfig = $null
        }
    }

    if ($existingConfig) {
        $hasMarker = $existingConfig.ContainsKey('_managed_by') -and (
            $existingConfig._managed_by -like "*$($Script:ManagedByMarker)*" -or
            $existingConfig._managed_by -like '*tools\desktop-mcp\install.ps1*'
        )
        $existingServers = if ($existingConfig.ContainsKey('mcpServers') -and $existingConfig.mcpServers) {
            @($existingConfig.mcpServers.Keys)
        } else { @() }
        $desiredKeys = @($DesiredServers.Keys)

        $diff = Compare-Object -ReferenceObject $existingServers -DifferenceObject $desiredKeys
        $keysMatch = ($existingServers.Count -gt 0) -and ($existingServers.Count -eq $desiredKeys.Count) -and (-not $diff)

        if ($hasMarker -or $keysMatch) {
            $discriminator = if ($hasMarker) { '_managed_by marker present' } else { "all $($existingServers.Count) server keys match this script's set" }
            New-PreflightFinding -Severity 'PASS' -Check 'existing-config' `
                -Message "OUR-MANAGED ($discriminator). Replacing mcpServers wholesale + ensuring marker."
            $Script:ExistingClass = 'OUR-MANAGED'
        } else {
            $extras = @($existingServers | Where-Object { $_ -notin $desiredKeys })
            $missing = @($desiredKeys | Where-Object { $_ -notin $existingServers })
            $extraTxt = if ($extras.Count -gt 0) { $extras -join ', ' } else { '(none)' }
            $missingTxt = if ($missing.Count -gt 0) { $missing -join ', ' } else { '(none)' }
            New-PreflightFinding -Severity 'WARN' -Check 'existing-config' `
                -Message "Existing mcpServers does not match this script's set. Extras (will be REMOVED): $extraTxt. Missing (will be ADDED): $missingTxt." `
                -Remediation 'Pre-write snapshot will preserve the current state at <config>.<timestamp>.bak. If you want to keep extras, copy them out first OR manually merge after this write.'
            $Script:ExistingClass = 'FOREIGN-OR-MERGED'
        }
    }

    # 3. Path safety — reparse-point detection on target dir
    $targetDir = Split-Path $Resolved.Path -Parent
    if (Test-Path $targetDir) {
        $dirItem = Get-Item -Force -Path $targetDir -ErrorAction SilentlyContinue
        if ($dirItem -and ($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $linkTarget = if ($dirItem.PSObject.Properties.Name -contains 'Target' -and $dirItem.Target) { $dirItem.Target } else { '(unresolved)' }
            New-PreflightFinding -Severity 'WARN' -Check 'path-safety' `
                -Message "Target dir '$targetDir' is a reparse point. Underlying target: $linkTarget." `
                -Remediation 'Confirm the link resolves where Desktop expects. Reparse points can redirect to a different filesystem than Desktop reads at runtime.'
        } else {
            New-PreflightFinding -Severity 'PASS' -Check 'path-safety' -Message 'Target dir is a regular directory.'
        }

        # 4. Writability probe (try/finally cleanup so we never leak the probe file).
        # Force probe to run even under -WhatIf: it must actually attempt a write to
        # produce a meaningful signal. The probe is non-destructive (9-byte file
        # removed in finally) — bypassing WhatIf is correct for diagnostic probes.
        $probePath = Join-Path $targetDir ".desktop-mcp-preflight-probe.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            'preflight' | Set-Content -Path $probePath -Encoding utf8 -NoNewline -ErrorAction Stop -WhatIf:$false -Confirm:$false
            New-PreflightFinding -Severity 'PASS' -Check 'writable' -Message 'Target dir is writable (probe succeeded).'
        } catch {
            New-PreflightFinding -Severity 'FAIL' -Check 'writable' `
                -Message "Cannot write to target dir: $($_.Exception.Message)" `
                -Remediation 'Check ACLs, Defender real-time-scan exclusions, and AV locks on the Claude-3p dir.'
        } finally {
            if (Test-Path $probePath) {
                Remove-Item -Path $probePath -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
            }
        }
    } else {
        New-PreflightFinding -Severity 'WARN' -Check 'path-safety' `
            -Message "Target dir '$targetDir' does not exist yet; will be created on first write." `
            -Remediation 'Normal for fresh-install scenarios. Confirm Desktop has launched at least once to create its app dir.'
    }

    # 5. Backup integrity — recursively-wrapped .backup is a known corruption shape
    $backupPath = "$($Resolved.Path).backup"
    if (Test-Path $backupPath) {
        try {
            $backup = Get-Content -Raw -Path $backupPath | ConvertFrom-Json -AsHashtable
            $recursive = $backup -is [hashtable] -and $backup.ContainsKey('mcpServers') -and `
                $backup.mcpServers -is [hashtable] -and $backup.mcpServers.ContainsKey('mcpServers')
            if ($recursive) {
                New-PreflightFinding -Severity 'FAIL' -Check 'backup-integrity' `
                    -Message 'Canonical .backup is recursively wrapped (.mcpServers.mcpServers exists). Cannot trust as rollback target.' `
                    -Remediation "Inspect $backupPath manually. If a clean pre-install state exists in another <config>.*.bak, copy it over .backup; otherwise delete .backup and re-run (next run captures a fresh canonical backup from the CURRENT state — be aware this loses any earlier pre-install state)."
            } else {
                New-PreflightFinding -Severity 'PASS' -Check 'backup-integrity' -Message 'Canonical .backup present and well-formed.'
            }
        } catch {
            New-PreflightFinding -Severity 'WARN' -Check 'backup-integrity' `
                -Message ".backup file present but invalid JSON: $($_.Exception.Message)" `
                -Remediation "Consider deleting $backupPath manually; next run will write a fresh canonical backup from current state."
        }
    } else {
        New-PreflightFinding -Severity 'PASS' -Check 'backup-integrity' -Message 'No canonical .backup present yet.'
    }

    # 6. Smell test — unexpected top-level keys
    if ($existingConfig) {
        $whitelist = @('mcpServers', 'preferences', '_managed_by')
        $unexpected = @($existingConfig.Keys | Where-Object { $_ -notin $whitelist })
        if ($unexpected.Count -gt 0) {
            New-PreflightFinding -Severity 'WARN' -Check 'smell-test' `
                -Message "Existing config has unexpected top-level keys: $($unexpected -join ', '). These will be PRESERVED by the merge but may signal a different Desktop variant or third-party tool." `
                -Remediation 'If these came from another tool, verify it does not conflict with what this script writes.'
        } else {
            New-PreflightFinding -Severity 'PASS' -Check 'smell-test' -Message 'No unexpected top-level keys.'
        }
    }

    # 6a. Connector overlap — surface known hosted-Connector ↔ our-server dual-client risks.
    # Desktop's Connector list is not on the filesystem (app-internal state), so this is
    # informational rather than a state probe. Hardcoded conflict table — extend as
    # Anthropic ships more hosted Connectors that overlap with servers in this script.
    $overlap = Get-ConnectorOverlap -DesiredServers $DesiredServers
    if ($overlap.Count -gt 0) {
        foreach ($k in $overlap.Keys) {
            New-PreflightFinding -Severity 'WARN' -Check "connector-overlap-$k" `
                -Message "Hosted Connector overlap on '$k': $($overlap[$k])" `
                -Remediation "Pick ONE: either disable the '$k' Custom Integration in Settings > Integrations before relaunch, OR remove '$k' from this script's mcpServers block. Running both produces two parallel clients on one identity."
        }
    } else {
        New-PreflightFinding -Severity 'PASS' -Check 'connector-overlap' -Message 'No known hosted Connector overlap with the configured servers.'
    }

    # 7-10. Prereq checks (folded into preflight for uniform PASS/WARN/FAIL gating)
    $fnm = Get-Command fnm -ErrorAction SilentlyContinue
    if (-not $fnm) {
        New-PreflightFinding -Severity 'FAIL' -Check 'prereq-fnm' `
            -Message 'fnm not on persistent User PATH.' `
            -Remediation 'winget install Schniz.fnm'
    } else {
        New-PreflightFinding -Severity 'PASS' -Check 'prereq-fnm' -Message "fnm at $($fnm.Source)"
    }

    if (-not (Test-Path $GithubEventsBuild)) {
        New-PreflightFinding -Severity 'FAIL' -Check 'prereq-github-events-build' `
            -Message "github-events build artifact missing: $GithubEventsBuild" `
            -Remediation 'bash tools/bootstrap.sh'
    } else {
        New-PreflightFinding -Severity 'PASS' -Check 'prereq-github-events-build' -Message 'github-events build present.'
    }

    if (-not (Test-Path $Context7Bat)) {
        New-PreflightFinding -Severity 'FAIL' -Check 'prereq-context7-launcher' `
            -Message "context7-launcher.bat missing: $Context7Bat" `
            -Remediation 'git checkout / re-pull this branch — the .bat ships from the repo.'
    } else {
        New-PreflightFinding -Severity 'PASS' -Check 'prereq-context7-launcher' -Message 'context7-launcher.bat present.'
    }

    if (-not (Test-Path $RefBat)) {
        New-PreflightFinding -Severity 'FAIL' -Check 'prereq-ref-launcher' `
            -Message "ref-launcher.bat missing: $RefBat" `
            -Remediation 'git checkout / re-pull this branch — the .bat ships from the repo.'
    } else {
        New-PreflightFinding -Severity 'PASS' -Check 'prereq-ref-launcher' -Message 'ref-launcher.bat present.'
    }

    $envChecks = [ordered]@{
        'CONTEXT7_API_KEY'   = 'context7 will 401 without it'
        'REF_API_KEY'        = 'ref will 401 without it'
        'PERPLEXITY_API_KEY' = 'perplexity will 401 without it'
    }
    foreach ($k in $envChecks.Keys) {
        $v = [Environment]::GetEnvironmentVariable($k, 'User')
        if ($v) {
            New-PreflightFinding -Severity 'PASS' -Check "prereq-env-$k" -Message "$k set (len=$($v.Length))"
        } else {
            New-PreflightFinding -Severity 'FAIL' -Check "prereq-env-$k" `
                -Message "$k not set in User env." `
                -Remediation "setx $k <value>  ($($envChecks[$k]))"
        }
    }
}

# ---------------------------------------------------------------- resolve target path

$resolved = Resolve-ClaudeDesktopConfigPath
$ConfigPath = $resolved.Path
$BackupPath = "$ConfigPath.backup"

Write-Host "Repo root:      $RepoRoot"
Write-Host ''

# ---------------------------------------------------------------- build desired mcpServers block (needed by preflight for existing-config comparison)

$whBuild = Join-Path $RepoRoot 'mcp-servers\github-events\node\build\subscriber\index.js'
$ctx7Bat = Join-Path $RepoRoot 'tools\desktop-mcp\context7-launcher.bat'
$refBat = Join-Path $RepoRoot 'tools\desktop-mcp\ref-launcher.bat'

$mcpServers = [ordered]@{
    aspire                  = [ordered]@{
        command = 'aspire'
        args    = @('agent', 'mcp')
    }
    ccusage                 = [ordered]@{
        command = 'fnm'
        args    = @('exec', '--using=default', '--', 'cmd', '/c', 'npx', '-y', '@ccusage/mcp@18.0.11')
    }
    'chrome-devtools'       = [ordered]@{
        command = 'fnm'
        args    = @('exec', '--using=default', '--', 'cmd', '/c', 'npx', '-y', 'chrome-devtools-mcp@0.23.0', '--port=9222', '--channel=stable')
    }
    context7                = [ordered]@{
        command = $ctx7Bat
    }
    granola                 = [ordered]@{
        command = 'fnm'
        args    = @('exec', '--using=default', '--', 'cmd', '/c', 'npx', '-y', 'mcp-remote', 'https://mcp.granola.ai/mcp')
    }
    'microsoft-learn'       = [ordered]@{
        command = 'fnm'
        args    = @('exec', '--using=default', '--', 'cmd', '/c', 'npx', '-y', 'mcp-remote', 'https://learn.microsoft.com/api/mcp', '--transport', 'http-only')
    }
    nuget                   = [ordered]@{
        command = 'dotnet'
        args    = @('dnx', 'NuGet.Mcp.Server', '--source', 'https://api.nuget.org/v3/index.json', '--yes')
    }
    'openai-developer-docs' = [ordered]@{
        command = 'fnm'
        args    = @('exec', '--using=default', '--', 'cmd', '/c', 'npx', '-y', 'mcp-remote', 'https://developers.openai.com/mcp', '--transport', 'http-only')
    }
    perplexity              = [ordered]@{
        command = 'fnm'
        args    = @('exec', '--using=default', '--', 'cmd', '/c', 'npx', '-y', '@perplexity-ai/mcp-server@0.9.0')
    }
    ref                     = [ordered]@{
        command = $refBat
    }
    'github-events'         = [ordered]@{
        # Direct spawn — no main-repo-run.js wrapper. That wrapper exists for CC's
        # worktree path-resolution problem and breaks under Desktop (Desktop spawns
        # from a non-repo CWD, so the wrapper's `git rev-parse --git-common-dir`
        # would fail). The server's ESM imports are relative to its own files,
        # not CWD, so no CWD setup is needed.
        command = 'fnm'
        args    = @('exec', '--using=default', '--', 'node', $whBuild)
        env     = [ordered]@{
            GITHUB_EVENTS_PORT        = '8788'
            GITHUB_EVENTS_BROKER_PORT = '8789'
            GITHUB_EVENTS_BROKER_URL  = 'http://127.0.0.1:8789'
            GITHUB_EVENTS_FILTER      = 'all'
            GITHUB_EVENTS_QUEUE_SIZE  = '200'
            GITHUB_EVENTS_SECRET      = ''
        }
    }
}

# ---------------------------------------------------------------- preflight

Write-Host '=== Preflight ===' -ForegroundColor Cyan
Invoke-Preflight `
    -Resolved $resolved `
    -DesiredServers $mcpServers `
    -Context7Bat $ctx7Bat `
    -RefBat $refBat `
    -GithubEventsBuild $whBuild

$fails = @($Script:Findings | Where-Object { $_.Severity -eq 'FAIL' })
$warns = @($Script:Findings | Where-Object { $_.Severity -eq 'WARN' })
$passes = @($Script:Findings | Where-Object { $_.Severity -eq 'PASS' })

Write-Host ''
Write-Host '=== Preflight summary ===' -ForegroundColor Cyan
Write-Host ('  PASS: {0}   WARN: {1}   FAIL: {2}' -f $passes.Count, $warns.Count, $fails.Count)

if ($fails.Count -gt 0) {
    Write-Host ''
    Write-Host "Preflight: $($fails.Count) FAIL finding(s) block the write regardless of mode." -ForegroundColor Red
    if ($WhatIfPreference) {
        Write-Host '(WhatIf: would normally abort here; continuing to print the dry-run JSON for inspection.)' -ForegroundColor Yellow
    } else {
        exit 2
    }
} elseif ($warns.Count -gt 0) {
    Write-Host ''
    if ($NonInteractive) {
        Write-Host "NonInteractive mode: $($warns.Count) WARN finding(s) → aborting." -ForegroundColor Yellow
        if (-not $WhatIfPreference) { exit 2 }
        Write-Host '(WhatIf: would normally abort here; continuing.)' -ForegroundColor Yellow
    } elseif (-not $WhatIfPreference) {
        $reply = Read-Host "Proceed despite $($warns.Count) warning(s)? [y/N]"
        if ($reply -notmatch '^[Yy]') {
            Write-Host 'Aborted by user.'
            exit 2
        }
    }
} else {
    Write-Host 'Preflight: all clear.' -ForegroundColor Green
}

# ---------------------------------------------------------------- merge with existing config

if (Test-Path $ConfigPath) {
    $existing = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json -AsHashtable
} else {
    $existing = [ordered]@{}
}

# Replace mcpServers wholesale (don't deep-merge per-server). Other top-level
# keys (preferences, unexpected-but-preserved) carry through.
$existing['mcpServers'] = $mcpServers
$existing['_managed_by'] = $Script:ManagedByMarker

# Re-emit ordered for deterministic output (PowerShell hashtable enumeration
# is non-deterministic; we want predictable diffs across re-runs).
$ordered = [ordered]@{}
foreach ($k in @('_managed_by', 'mcpServers') + @($existing.Keys | Where-Object { $_ -notin @('_managed_by', 'mcpServers') } | Sort-Object)) {
    if ($existing.ContainsKey($k)) {
        $ordered[$k] = $existing[$k]
    }
}

$merged = $ordered | ConvertTo-Json -Depth 64

# ---------------------------------------------------------------- write or print

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host '--- WHATIF: would write the following content ---' -ForegroundColor Yellow
    Write-Output $merged
    Write-Host '--- WHATIF: end ---' -ForegroundColor Yellow
    exit 0
}

try {
    if (Test-Path $ConfigPath) {
        # Preserve the *original* pre-install state. Re-runs MUST NOT overwrite
        # the canonical .backup (or every re-run would corrupt the rollback target).
        # Write the canonical backup only on first run.
        if (-not (Test-Path $BackupPath)) {
            Copy-Item -Path $ConfigPath -Destination $BackupPath -Force
            Write-Host "Canonical backup written: $BackupPath" -ForegroundColor Green
        } else {
            Write-Host "Canonical backup preserved: $BackupPath (already exists from first install)" -ForegroundColor Yellow
        }
        # Also write a timestamped pre-write snapshot for re-run safety.
        $stamp = Get-Date -Format 'yyyyMMddTHHmmssZ' -AsUTC
        $rotating = "$ConfigPath.$stamp.bak"
        Copy-Item -Path $ConfigPath -Destination $rotating -Force
        Write-Host "Pre-write snapshot: $rotating"
    }
    # atomic-ish write (PowerShell does temp+rename via Set-Content)
    $merged | Set-Content -Path $ConfigPath -Encoding utf8 -NoNewline
} catch {
    Write-Host ''
    Write-Host "Write failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "Wrote $ConfigPath" -ForegroundColor Green
Write-Host "mcpServers count:    $($mcpServers.Count)"
Write-Host "_managed_by marker:  $($Script:ManagedByMarker)"
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Fully quit Claude Desktop (system tray -> Quit, NOT just close window).'
Write-Host '  2. Relaunch.'
Write-Host '  3. Open Settings > Integrations to confirm servers appear.'
Write-Host '  4. Run tools/desktop-mcp/verify.ps1 to confirm each server still spawns + handshakes (Tier 2).'
Write-Host '  5. Tier 3: confirm Desktop emits per-server logs at the paths below — only then is the config proven loaded by Desktop.'
Write-Host '  6. First granola connection opens browser for OAuth (token cached to ~/.mcp-auth/).'
Write-Host ''
Write-Host 'Logs (best-effort locations — actual path depends on Desktop variant):' -ForegroundColor Cyan
Write-Host "  - $env:APPDATA\Claude\logs\mcp-server-*.log              (classic Claude Desktop)"
Write-Host "  - $env:LOCALAPPDATA\Claude-3p\logs\                      (current Anthropic Desktop, if used)"
Write-Host "  - $env:LOCALAPPDATA\Claude Nest-3p\                      (current Anthropic Desktop runtime)"
