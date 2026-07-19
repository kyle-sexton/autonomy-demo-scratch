#Requires -Version 7.4
<#
.SYNOPSIS
Pester v5 test runner for the tools/*.Tests.ps1 suite.

.DESCRIPTION
Runs all Pester tests matching tools/powershell/*.Tests.ps1 recursively. Loads config from
tools/powershell/PesterConfiguration.psd1 and absolutizes TestResult.OutputPath against
the repo root so output always lands in artifacts/test-results/ regardless of
caller CWD. Mirrors .claude/skills/machine-health/tests/Invoke-MachineHealthTests.ps1.

.PARAMETER Filter
Wildcard applied to the test file BaseName (e.g., 'Invoke-Pssa' runs
Invoke-Pssa.Tests.ps1 only).

.PARAMETER ListOnly
Discover tests and print the file list without executing.

.EXAMPLE
pwsh -NoProfile -File tools/powershell/Invoke-ToolsTests.ps1
Runs all tools/powershell/*.Tests.ps1 tests; writes results to artifacts/test-results/.

.EXAMPLE
pwsh -NoProfile -File tools/powershell/Invoke-ToolsTests.ps1 -Filter Invoke-Pssa
Runs only Invoke-Pssa.Tests.ps1.

.EXAMPLE
pwsh -NoProfile -File tools/powershell/Invoke-ToolsTests.ps1 -ListOnly
Prints discovered test file paths and exits.
#>
[CmdletBinding()]
param(
    [string] $Filter,
    [switch] $ListOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$minPester = [version]'5.7.0'
$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version -lt $minPester) {
    $install = "Install-Module Pester -MinimumVersion $minPester -Scope CurrentUser -Force"
    Write-Error "Pester $minPester+ required. $install"
    exit 1
}
Import-Module Pester -MinimumVersion $minPester -Force

$toolsRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $toolsRoot)

. (Join-Path (Split-Path -Parent $toolsRoot) 'shared/pester/PesterWorkflowAnnotation.ps1')

$testFiles = Get-ChildItem -LiteralPath $toolsRoot -Recurse -Filter '*.Tests.ps1' -File
if (-not $testFiles) {
    Write-Warning 'No test files found in tools/.'
    exit 0
}
if ($Filter) {
    $testFiles = $testFiles | Where-Object { $_.BaseName -like "*$Filter*" }
}

if ($ListOnly) {
    $testFiles | ForEach-Object { $_.FullName }
    return
}

if (-not $testFiles) {
    Write-Warning 'No test files matched filter.'
    exit 0
}

$configPath = Join-Path $toolsRoot 'PesterConfiguration.psd1'
$configHash = Import-PowerShellDataFile -LiteralPath $configPath
$config = New-PesterConfiguration -Hashtable $configHash
$config.Run.Path = $testFiles.FullName

# Absolutize OutputPath against repo root. Pester's TestResult.OutputPath is
# CWD-relative by default -- without absolutization, output lands wherever
# pwsh was invoked from (root cause of the testResults.xml leak this SSOT
# eliminates). $configHash is a plain hashtable from Import-PowerShellDataFile,
# so $configHash.TestResult.OutputPath is a bare string (the typed
# PesterConfiguration.TestResult.OutputPath property's ToString() embeds
# help text and is not safe to use with Split-Path / Join-Path).
$absoluteOutputPath = Join-Path $repoRoot $configHash.TestResult.OutputPath
$config.TestResult.OutputPath = $absoluteOutputPath

# Ensure output directory exists. Pester does not create parent dirs.
$outputDir = Split-Path -Parent $absoluteOutputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$result = Invoke-Pester -Configuration $config

# CI diagnostics: when running under GitHub Actions and at least one test
# failed, emit workflow-command annotations + step-summary markdown so the
# failure names and messages surface on the check-run page. Helper functions
# come from tools/shared/pester/PesterWorkflowAnnotation.ps1 (dot-sourced above).
# Localhost runs are unaffected.

if ($env:GITHUB_ACTIONS -eq 'true' -and $result.FailedCount -gt 0) {
    Write-Output ''
    Write-Output "::group::Pester failure summary ($($result.FailedCount) failed)"
    foreach ($t in $result.Failed) {
        $info = Get-FailedTestInfo -Test $t
        $collapsed = $info.Message -replace "`r?`n", ' | '
        $safeTitle = ConvertTo-WorkflowCommandProperty ('Pester: ' + $info.Path)
        $safeMessage = ConvertTo-WorkflowCommandMessage $collapsed
        Write-Output "::error title=${safeTitle}::${safeMessage}"
    }
    Write-Output '::endgroup::'

    if ($result.Containers) {
        foreach ($c in $result.Containers) {
            if ($c.Result -eq 'Failed' -and $c.ErrorRecord) {
                foreach ($err in $c.ErrorRecord) {
                    $msg = if ($err.Exception) { $err.Exception.Message } else { "$err" }
                    $collapsed = $msg -replace "`r?`n", ' | '
                    $safeTitle = ConvertTo-WorkflowCommandProperty ('Pester-Container: ' + $c.Item)
                    $safeMessage = ConvertTo-WorkflowCommandMessage $collapsed
                    Write-Output "::error title=${safeTitle}::${safeMessage}"
                }
            }
        }
    }

    if ($env:GITHUB_STEP_SUMMARY -and (Test-Path -LiteralPath $env:GITHUB_STEP_SUMMARY)) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('## Pester failure summary (tools suite)')
        $lines.Add('')
        $counts = "$($result.FailedCount) failed / $($result.PassedCount) passed / $($result.SkippedCount) skipped"
        $lines.Add("**$counts**")
        $lines.Add('')
        if ($result.Failed.Count -gt 0) {
            $lines.Add('### Failed tests')
            $lines.Add('')
            foreach ($t in $result.Failed) {
                $info = Get-FailedTestInfo -Test $t
                $lines.Add("- **$($info.Path)**")
                $lines.Add('  ```')
                foreach ($ln in ($info.Message -split "`r?`n")) {
                    $lines.Add("  $ln")
                }
                $lines.Add('  ```')
            }
        }
        if ($result.Containers) {
            $failedContainers = @($result.Containers | Where-Object { $_.Result -eq 'Failed' -and $_.ErrorRecord })
            if ($failedContainers.Count -gt 0) {
                $lines.Add('### Failed containers (BeforeAll / discovery)')
                $lines.Add('')
                foreach ($c in $failedContainers) {
                    $lines.Add("- **$($c.Item)**")
                    foreach ($err in $c.ErrorRecord) {
                        $msg = if ($err.Exception) { $err.Exception.Message } else { "$err" }
                        $lines.Add('  ```')
                        foreach ($ln in ($msg -split "`r?`n")) {
                            $lines.Add("  $ln")
                        }
                        $lines.Add('  ```')
                    }
                }
            }
        }
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") -Encoding utf8
    }
}

exit $result.FailedCount
