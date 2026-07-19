#Requires -Version 7.4
<#
.SYNOPSIS
    Pester v5 tests for tools/powershell/Invoke-Pssa.ps1.

.DESCRIPTION
    Black-box tests of the Invoke-PssaWithIsolation function. Dot-sources
    the script with dummy args so the dot-source guard returns before the
    main block fires, exposing the function for test invocation with
    mocked pwsh subprocess. Pattern: .claude/rules/powershell/conventions.md
    "Mocks do NOT propagate through `&`-invoked `.ps1` scripts" -- "Canonical
    pattern".
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:HasPssa = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Invoke-Pssa.ps1'
    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-pssa-test-' + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # Minimal settings hashtable file -- mocks bypass real PSSA invocation,
    # so contents do not matter beyond Test-Path / parameter binding.
    $script:SettingsPath = Join-Path $script:TempDir 'PSScriptAnalyzerSettings.psd1'
    Set-Content -LiteralPath $script:SettingsPath -Value "@{ Severity = @('Error','Warning') }" -Encoding utf8

    # Dot-source with valid-but-throwaway args so param() binding succeeds
    # and the dot-source guard inside Invoke-Pssa.ps1 returns before the main
    # body runs. This exposes Invoke-PssaWithIsolation for in-scope testing
    # while Mock can intercept pwsh subprocess calls.
    $script:DummyList = Join-Path $script:TempDir 'dummy-list.txt'
    [System.IO.File]::WriteAllText($script:DummyList, '')
    $script:DummyResults = Join-Path $script:TempDir 'dummy-results.xml'
    $dotSourceParams = @{
        FileListPath = $script:DummyList
        SettingsPath = $script:SettingsPath
        ResultsPath  = $script:DummyResults
    }
    . $script:ScriptPath @dotSourceParams
}

AfterAll {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force
    }
}

Describe 'Invoke-PssaWithIsolation' {
    BeforeEach {
        $script:CaseDir = Join-Path $script:TempDir ('case-' + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:CaseDir -Force | Out-Null
        $script:FileList = Join-Path $script:CaseDir 'files.txt'
        $script:Results = Join-Path $script:CaseDir 'results.xml'
    }

    AfterEach {
        if ($script:CaseDir -and (Test-Path -LiteralPath $script:CaseDir)) {
            Remove-Item -LiteralPath $script:CaseDir -Recurse -Force
        }
    }

    It 'returns 0 when file list is empty' {
        # Zero-byte file: Get-Content returns $null, ForEach-Object emits
        # nothing, $results stays falsy, function returns 0.
        [System.IO.File]::WriteAllText($script:FileList, '')

        $params = @{
            FileListPath = $script:FileList
            SettingsPath = $script:SettingsPath
            ResultsPath  = $script:Results
        }
        $code = Invoke-PssaWithIsolation @params
        $code | Should -Be 0
        (Test-Path -LiteralPath $script:Results) | Should -BeFalse
    }

    It 'returns 0 when analyzer emits no findings' {
        $cleanFile = Join-Path $script:CaseDir 'clean.ps1'
        Set-Content -LiteralPath $cleanFile -Value 'Write-Output "clean"' -Encoding utf8
        Set-Content -LiteralPath $script:FileList -Value $cleanFile -Encoding utf8

        Mock pwsh { return '' }

        $params = @{
            FileListPath = $script:FileList
            SettingsPath = $script:SettingsPath
            ResultsPath  = $script:Results
        }
        $code = Invoke-PssaWithIsolation @params
        $code | Should -Be 0
        (Test-Path -LiteralPath $script:Results) | Should -BeFalse
        Should -Invoke pwsh -Times 1 -Exactly
    }

    It 'returns 1 and writes Clixml when findings emitted' {
        $dirtyFile = Join-Path $script:CaseDir 'dirty.ps1'
        Set-Content -LiteralPath $dirtyFile -Value 'Write-Host "uses Write-Host"' -Encoding utf8
        Set-Content -LiteralPath $script:FileList -Value $dirtyFile -Encoding utf8

        Mock pwsh {
            $finding = [pscustomobject]@{
                RuleName   = 'PSAvoidUsingWriteHost'
                Severity   = 'Warning'
                Line       = 1
                Message    = 'Avoid Write-Host.'
                ScriptName = 'dirty.ps1'
            }
            return ($finding | ConvertTo-Clixml)
        }

        $params = @{
            FileListPath = $script:FileList
            SettingsPath = $script:SettingsPath
            ResultsPath  = $script:Results
        }
        $code = Invoke-PssaWithIsolation @params
        $code | Should -Be 1
        (Test-Path -LiteralPath $script:Results) | Should -BeTrue

        $imported = @(Import-Clixml -LiteralPath $script:Results)
        $imported.Count | Should -Be 1
        $imported[0].RuleName | Should -Be 'PSAvoidUsingWriteHost'
    }

    It 'runs the full ruleset without CI ExcludeRule overlays' {
        $someFile = Join-Path $script:CaseDir 'some.ps1'
        Set-Content -LiteralPath $someFile -Value 'Write-Output "x"' -Encoding utf8
        Set-Content -LiteralPath $script:FileList -Value $someFile -Encoding utf8

        Mock pwsh {
            param([string]$Command)
            $Command | Should -Match 'Invoke-ScriptAnalyzer'
            $Command | Should -Not -Match 'ExcludeRule'
            return ''
        }

        $params = @{
            FileListPath = $script:FileList
            SettingsPath = $script:SettingsPath
            ResultsPath  = $script:Results
        }
        Invoke-PssaWithIsolation @params | Should -Be 0
        Should -Invoke pwsh -Times 1 -Exactly
    }

    It 'propagates terminating errors from analyzer and writes no results file' {
        $someFile = Join-Path $script:CaseDir 'some.ps1'
        Set-Content -LiteralPath $someFile -Value 'Write-Output "x"' -Encoding utf8
        Set-Content -LiteralPath $script:FileList -Value $someFile -Encoding utf8

        Mock pwsh { throw 'simulated PSSA crash' }

        $params = @{
            FileListPath = $script:FileList
            SettingsPath = $script:SettingsPath
            ResultsPath  = $script:Results
        }
        { Invoke-PssaWithIsolation @params } | Should -Throw '*simulated PSSA crash*'
        (Test-Path -LiteralPath $script:Results) | Should -BeFalse
    }
}

Describe 'Invoke-PssaWithIsolation integration' {
    It 'marshals DiagnosticRecord objects across the pwsh subprocess boundary' -Skip:(-not $script:HasPssa) {
        $caseDir = Join-Path $script:TempDir ('integration-' + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
        $dirtyFile = Join-Path $caseDir 'dirty.ps1'
        Set-Content -LiteralPath $dirtyFile -Value 'Write-Host "uses Write-Host"' -Encoding utf8
        $fileList = Join-Path $caseDir 'files.txt'
        Set-Content -LiteralPath $fileList -Value $dirtyFile -Encoding utf8
        $results = Join-Path $caseDir 'results.xml'

        $params = @{
            FileListPath = $fileList
            SettingsPath = $script:SettingsPath
            ResultsPath  = $results
        }
        $code = Invoke-PssaWithIsolation @params
        $code | Should -Be 1
        (Test-Path -LiteralPath $results) | Should -BeTrue

        $imported = @(Import-Clixml -LiteralPath $results)
        $imported.Count | Should -Be 1
        $imported[0].RuleName | Should -Be 'PSAvoidUsingWriteHost'
        $imported[0].Severity | Should -Not -BeNullOrEmpty
        $imported[0].Line | Should -BeGreaterThan 0
    }
}
