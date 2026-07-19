#requires -Version 7
<#
.SYNOPSIS
  Verify Claude Desktop MCP parity: each configured server responds to the
  MCP initialize handshake.

.DESCRIPTION
  Reads the live claude_desktop_config.json (auto-detects MSIX vs Win32),
  spawns each server with the EXACT command + args + env from the config,
  pipes a JSON-RPC 'initialize' request to its stdin, drains stdout until
  the response or timeout, then closes stdin. Mirrors Desktop's spawn
  semantics (Windows CreateProcess via System.Diagnostics.Process).

.PARAMETER TimeoutSeconds
  Per-server handshake wait. Defaults to 30s. Slow first-run npx downloads
  (ccusage, chrome-devtools, mcp-remote first install) may need 60+.

.PARAMETER OnlyName
  If specified, run the handshake for just this one server. Debugging shortcut.

.PARAMETER Verbose
  Print stdout/stderr capture on FAIL.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive operator verification tool; colored Write-Host is the intended UX surface.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidLongLines', '', Justification = 'JSON-RPC literals, regex patterns, and diagnostic messages exceed 120 chars.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Best-effort cleanup paths (StandardInput.Close, Process.Kill) where target may already be in terminal state.')]
param(
    [int]$TimeoutSeconds = 30,
    [string]$OnlyName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Resolve-ClaudeDesktopConfigPath {
    # Preferred: current Anthropic Desktop "-3p" (see install.ps1 for the asar
    # path-discovery rationale). Fall back to classic Win32, then vestigial MSIX.
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Claude-3p\claude_desktop_config.json'))
    $candidates.Add((Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'))
    Get-ChildItem -Path "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $candidates.Add((Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'))
    }
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    throw 'No claude_desktop_config.json found.'
}

function Test-McpHandshake {
    param([string]$Name, [hashtable]$Entry, [int]$WaitSeconds)

    $command = $Entry.command
    $arguments = if ($Entry.ContainsKey('args')) { $Entry.args } else { @() }
    $envOverride = if ($Entry.ContainsKey('env')) { $Entry.env } else { @{} }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $command
    foreach ($a in $arguments) { $psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in $envOverride.Keys) { $psi.Environment[$k] = [string]$envOverride[$k] }

    $initJson = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}'

    # Stdout handler matches each line as it arrives (MCP JSON-RPC is
    # line-delimited) and posts the first match to a TaskCompletionSource the
    # main thread waits on. Avoids re-scanning the entire accumulated buffer on
    # every poll tick. Stderr stays StringBuilder because the failure-path code
    # reads it as one blob.
    $stdoutTcs = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
    $stderrSb = [System.Text.StringBuilder]::new()
    $response = $null

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $stdoutHandler = {
        if (-not $EventArgs.Data) { return }
        $tcs = $Event.MessageData
        if ($tcs.Task.IsCompleted) { return }
        if ($EventArgs.Data -match '"jsonrpc"' -and ($EventArgs.Data -match '"result"' -or $EventArgs.Data -match '"error"')) {
            [void]$tcs.TrySetResult($EventArgs.Data.Trim())
        }
    }
    $stderrHandler = {
        if ($EventArgs.Data) {
            [void]$Event.MessageData.AppendLine($EventArgs.Data)
        }
    }
    $outEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $stdoutHandler -MessageData $stdoutTcs
    $errEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $stderrHandler -MessageData $stderrSb

    $verdict = 'NO-RESPONSE'
    $detail = ''
    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $proc.StandardInput.WriteLine($initJson)
        $proc.StandardInput.Flush()

        # Wait for a matching line, capped by $WaitSeconds. Tick every 250ms so
        # we also short-circuit if the spawned server exits before producing one.
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        $procExited = $false
        while ((Get-Date) -lt $deadline) {
            if ($stdoutTcs.Task.Wait(250)) {
                $response = $stdoutTcs.Task.Result
                break
            }
            if ($proc.HasExited) { $procExited = $true; break }
        }

        # Register-ObjectEvent handlers run asynchronously and can lag the
        # process-exit signal by a tick. A server that writes a valid response
        # and exits quickly may not have set $stdoutTcs by the time HasExited
        # is observed. Drain the TCS once more before giving up.
        if ($procExited -and -not $response -and $stdoutTcs.Task.Wait(1000)) {
            $response = $stdoutTcs.Task.Result
        }
    } catch {
        $detail = "exception: $($_.Exception.Message)"
    } finally {
        # Close stdin to let server exit cleanly
        try { $proc.StandardInput.Close() } catch {}
        # Give it 2s to drain
        if (-not $proc.WaitForExit(2000)) {
            try { $proc.Kill($true) } catch {}
        }
        Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue
        Remove-Job -Job $outEvent -Force -ErrorAction SilentlyContinue
        Remove-Job -Job $errEvent -Force -ErrorAction SilentlyContinue
        $proc.Dispose()
    }

    if ($response) {
        try {
            $parsed = $response | ConvertFrom-Json -AsHashtable
            if ($parsed.ContainsKey('result') -and $parsed.result.ContainsKey('protocolVersion')) {
                $verdict = 'PASS'
                $detail = "protocolVersion=$($parsed.result.protocolVersion); name=$($parsed.result.serverInfo.name)/$($parsed.result.serverInfo.version)"
            } elseif ($parsed.ContainsKey('error')) {
                $verdict = 'RPC-ERROR'
                $detail = $parsed.error.message
            }
        } catch {
            $verdict = 'INVALID-JSON'
            $detail = $response.Substring(0, [Math]::Min($response.Length, 200))
        }
    } else {
        # No JSON-RPC response captured. Inspect stderr to distinguish expected
        # OAuth-pending state from real failures.
        $stderrText = $stderrSb.ToString()
        if ($stderrText -match 'Authentication required|Waiting for authorization|OAuth callback server running') {
            $verdict = 'OAUTH-PENDING'
            $detail = 'mcp-remote spawned OAuth flow; complete the in-browser auth in Claude Desktop on first launch. Token cached to ~/.mcp-auth/ afterward.'
        } elseif ($stderrText -and -not $detail) {
            $tail = $stderrText.TrimEnd().Split("`n") | Select-Object -Last 3
            $detail = 'stderr tail: ' + ($tail -join ' | ')
        }
    }

    return [pscustomobject]@{ Name = $Name; Verdict = $verdict; Detail = $detail }
}

$ConfigPath = Resolve-ClaudeDesktopConfigPath
$cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable
Write-Host "Config:  $ConfigPath"
Write-Host "Servers: $($cfg.mcpServers.Keys.Count) configured"
Write-Host ''

$serverNames = if ($OnlyName) { @($OnlyName) } else { $cfg.mcpServers.Keys | Sort-Object }

$pass = 0
$oauthPending = 0
$fail = 0
foreach ($name in $serverNames) {
    Write-Host "[$name] testing... " -NoNewline
    $result = Test-McpHandshake -Name $name -Entry $cfg.mcpServers[$name] -WaitSeconds $TimeoutSeconds
    switch ($result.Verdict) {
        'PASS' {
            Write-Host 'PASS' -ForegroundColor Green -NoNewline
            Write-Host "  $($result.Detail)"
            $pass++
        }
        'OAUTH-PENDING' {
            Write-Host 'OAUTH-PENDING' -ForegroundColor Yellow -NoNewline
            Write-Host "  $($result.Detail)"
            $oauthPending++
        }
        default {
            Write-Host "FAIL ($($result.Verdict))" -ForegroundColor Red -NoNewline
            Write-Host "  $($result.Detail)"
            $fail++
        }
    }
}

Write-Host ''
Write-Host '========================================'
$total = $pass + $oauthPending + $fail
$summaryColor = if ($fail -gt 0) { 'Red' } elseif ($oauthPending -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "Summary: $pass PASS, $oauthPending OAUTH-PENDING, $fail FAIL of $total servers" -ForegroundColor $summaryColor
if ($oauthPending -gt 0) {
    Write-Host 'OAuth-pending servers need first-time auth in Claude Desktop UI; this is expected.' -ForegroundColor Yellow
}
if ($fail -gt 0) { exit 1 }
