# PSScriptAnalyzer settings for scripts/windows and tools. Every Error and Warning rule runs (Information-level rules
# don't), except:
# - PSAvoidUsingWriteHost: these are interactive scripts a person reads, and Write-Host is how they print
#   coloured PASS and FAIL lines. Nothing pipes their output.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
