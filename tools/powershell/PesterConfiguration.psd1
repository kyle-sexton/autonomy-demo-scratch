# Pester v5 configuration for the tools/*.Tests.ps1 suite.
# Loaded by tools/Invoke-ToolsTests.ps1 via Import-PowerShellDataFile + New-PesterConfiguration.
#
# OutputPath is repo-root-relative; the runner absolutizes it via
# Join-Path $repoRoot $configHash.TestResult.OutputPath before passing to
# Pester. Pester's native OutputPath is CWD-relative -- absolutizing in the
# runner prevents `testResults.xml`-style leaks when invoked from any CWD.
#
# Output convention parity with .NET: see .claude/rules/testing.md
# "artifacts/test-results/" and .claude/rules/dotnet-conventions.md
# "Capturing test failure detail".
@{
    Run          = @{
        PassThru = $true
        Exit     = $true
        Throw    = $false
    }
    Filter       = @{
        Tag = @()
    }
    Output       = @{
        Verbosity           = 'Detailed'
        StackTraceVerbosity = 'Filtered'
        CIFormat            = 'Auto'
    }
    CodeCoverage = @{
        Enabled = $false
    }
    TestResult   = @{
        Enabled      = $true
        OutputFormat = 'NUnitXml'
        OutputPath   = 'artifacts/test-results/tools-pester-results.xml'
    }
    Should       = @{
        ErrorAction = 'Stop'
    }
}
