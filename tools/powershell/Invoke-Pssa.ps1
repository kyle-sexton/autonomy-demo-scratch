#Requires -Version 7.4
<#
.SYNOPSIS
    Run PSScriptAnalyzer on a list of files using per-file subprocess isolation.

.DESCRIPTION
    Subprocess entry point used by `.github/workflows/shell-lint.yml`. Matches the
    lefthook pre-commit pattern (`.lefthook/pre-commit/psscriptanalyzer.sh`): one
    fresh `pwsh` subprocess per file with the full `PSScriptAnalyzerSettings.psd1`
    ruleset — no CI-only `-ExcludeRule` overlay.

    Per-file isolation avoids the PSScriptAnalyzer CommandInfoCache / RunspacePool
    race that appears when many files are analyzed inside one pwsh process. Upstream
    references and the historical CI exclude overlay live in
    `.claude/rules/ci-cd-conventions.md` "PSScriptAnalyzer Linux NRE flake".

.PARAMETER FileListPath
    Path to a newline-delimited file containing the .ps1/.psm1 paths to analyze.

.PARAMETER SettingsPath
    Path to the PSScriptAnalyzerSettings.psd1 file (typically the repo root settings).

.PARAMETER ResultsPath
    Path where serialized DiagnosticRecord[] should be written when findings exist.

.OUTPUTS
    Exit 0: no findings.
    Exit 1: findings present (serialized to $ResultsPath).
    Other (non-zero, no $ResultsPath written): PSSA crashed — investigate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FileListPath,

    [Parameter(Mandatory)]
    [string]$SettingsPath,

    [Parameter(Mandatory)]
    [string]$ResultsPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-PssaWithIsolation {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$FileListPath,

        [Parameter(Mandatory)]
        [string]$SettingsPath,

        [Parameter(Mandatory)]
        [string]$ResultsPath
    )

    $files = Get-Content -LiteralPath $FileListPath
    $allResults = @()

    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) {
            continue
        }

        $env:PSSA_FILE = $file
        $env:PSSA_SETTINGS = $SettingsPath
        $clixml = pwsh -NoProfile -NonInteractive -Command @'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
Invoke-ScriptAnalyzer -Path $env:PSSA_FILE -Settings $env:PSSA_SETTINGS | ConvertTo-Clixml
'@
        $subprocessExitCode = if (Test-Path -Path variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($subprocessExitCode -ne 0) {
            throw "PSScriptAnalyzer subprocess failed for $file (exit $subprocessExitCode)"
        }
        if ($clixml) {
            $clixmlTemp = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $clixmlTemp -Value $clixml -Encoding utf8NoBOM
                $fileResults = @(Import-Clixml -LiteralPath $clixmlTemp)
            } finally {
                Remove-Item -LiteralPath $clixmlTemp -Force -ErrorAction SilentlyContinue
            }
            if ($fileResults) {
                $allResults += $fileResults
            }
        }
    }

    if ($allResults) {
        $allResults | Export-Clixml -LiteralPath $ResultsPath
        return 1
    }

    return 0
}

if ($MyInvocation.InvocationName -eq '.') { return }

$exitCode = Invoke-PssaWithIsolation -FileListPath $FileListPath -SettingsPath $SettingsPath -ResultsPath $ResultsPath
exit $exitCode
