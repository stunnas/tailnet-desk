# PSScriptAnalyzer settings for scripts/windows and tools. Every Error and Warning rule runs (Information-level rules
# don't), except:
# - PSAvoidUsingWriteHost: these are interactive scripts a person reads, and Write-Host is how they print
#   coloured PASS and FAIL lines. Nothing pipes their output.
# PSUseCompatibleSyntax is off by default; it's on here so syntax newer than Windows PowerShell 5.1 fails the lint.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @('PSAvoidUsingWriteHost')
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
