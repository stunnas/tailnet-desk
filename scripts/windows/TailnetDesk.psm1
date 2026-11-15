# TailnetDesk: shared functions for the Windows host and controller scripts.
# Written for Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII only: Windows PowerShell 5.1 reads
# files without a byte order mark as the system code page, so other characters break.
#
# Sections: settings, checks (no system access; tests/windows covers them, plus most system functions with mocks;
# see the README's Status for what isn't),
# system reads, and system changes. Each system change says what it changes. The caller's $ErrorActionPreference
# doesn't reach a module, so system functions pass -ErrorAction Stop to every cmdlet whose failure matters.
#
# Threat model: the scripts run as administrator but trust the signed-in user's account and everything running as it.
# They are run from the user's Downloads folder, so a program running as the user could change them anyway, and
# winget is found through the user's PATH. Windows' own tools (icacls, powercfg) run from System32, found through
# the registry. The hardening below protects against mistakes and odd setups, not
# against such a program: system folders come from the machine registry rather than environment variables, and the
# downloaded installer sits in an admin-only folder, locked from its hash check until it exits.

Set-StrictMode -Version 3.0

# --- Settings ------------------------------------------------------------------------------------------------
# Versions are pinned and bumped by hand after testing; the SHA-256 is checked before anything runs.

$script:Setting = [pscustomobject]@{
    DirectPort      = 21118                 # RustDesk direct IP access (TCP)
    AdapterName     = 'Tailscale'           # Tailscale's network adapter on Windows
    ServiceName     = 'RustDesk'
    RuleNames       = @('RustDesk Service', 'rustdesk.exe')   # names RustDesk's installer gives its firewall rules
    RustDeskRepo    = 'rustdesk/rustdesk'   # the official GitHub repo; downloads come only from its releases
    # Released 2026-11-09. Bump together with RustDeskSha256, then re-test and update the README's Status.
    RustDeskVersion = '1.5.3'
    RustDeskSha256  = '523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249'
    # winget package Tailscale.Tailscale, released 2026-10-28; Tailscale updates itself afterwards.
    TailscaleWinget = '1.104.4'
}
$script:Setting | Add-Member -NotePropertyName RustDeskAsset -NotePropertyValue "rustdesk-$($script:Setting.RustDeskVersion)-x86_64.exe"

function Get-TailnetDeskSetting {
    <# .SYNOPSIS The shared settings: port, adapter and service names, and pinned versions. #>
    [CmdletBinding()]
    param()
    return $script:Setting
}

# --- Checks (no system access) -------------------------------------------------------------------------------

function Test-IPv4 {
    <# .SYNOPSIS True when the text is exactly one IPv4 address, written without leading zeros. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)

    # \z, not $: $ would also accept a trailing newline. [0-9], not \d: \d matches non-ASCII digits in .NET.
    if ($Address -notmatch '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}\z') { return $false }
    foreach ($part in $Address.Split('.')) { if ([int]$part -gt 255) { return $false } }
    return $true
}

function Test-TailscaleIPv4 {
    <#
    .SYNOPSIS
    True when the text is exactly one IPv4 address inside Tailscale's range, 100.64.0.0/10 (100.64.0.0 to
    100.127.255.255), written without leading zeros.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)

    if (-not (Test-IPv4 -Address $Address)) { return $false }
    $parts = $Address.Split('.') | ForEach-Object { [int]$_ }
    return ($parts[0] -eq 100 -and $parts[1] -ge 64 -and $parts[1] -le 127)
}

function ConvertTo-AddressList {
    <#
    .SYNOPSIS
    Turns addresses given as a list and/or comma-separated text into a clean list: trimmed, no blanks, no repeats.
    It doesn't judge them; Get-AddressFinding does.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Address = @())

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Address)) {
        if ($null -eq $item) { continue }
        foreach ($piece in $item.Split(',')) {
            $p = $piece.Trim()
            if ($p -and -not $list.Contains($p)) { $list.Add($p) }
        }
    }
    return $list.ToArray()
}

function Get-AddressFinding {
    <#
    .SYNOPSIS
    One result per address: each must be a single Tailscale address. A range, 0.0.0.0 or a home address would let in
    more than your controllers.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Address = @(), [string]$What = 'Controller address')

    foreach ($a in @($Address)) {
        [pscustomobject]@{
            Check  = "$What '$a' is one Tailscale address"
            Pass   = (Test-TailscaleIPv4 -Address $a)
            Detail = 'use the 100.x address from the Tailscale admin console; no ranges, no home addresses'
        }
    }
}

function Resolve-ControllerIp {
    <#
    .SYNOPSIS
    Which controllers to whitelist: the ones given, or, when none are given, the single Tailscale addresses already
    in RustDesk's whitelist (so a re-run keeps a working setup). Never this PC's own address (-OwnIp). Throws on an
    invalid given address or on this PC's own.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()][string[]]$ControllerIp = @(),
        [AllowEmptyString()][string]$CurrentWhitelist = '',
        [AllowEmptyString()][string]$OwnIp = ''
    )

    $given = @(ConvertTo-AddressList -Address $ControllerIp)
    if ($given.Count -gt 0) {
        foreach ($ip in $given) {
            if (-not (Test-TailscaleIPv4 -Address $ip)) {
                throw "Not a Tailscale address: '$ip'. Tailscale addresses start with 100. (100.64.0.0 to 100.127.255.255)."
            }
            if ($OwnIp -and $ip -eq $OwnIp) {
                throw "'$ip' is this PC's own address. Use the controller's address instead."
            }
        }
        return $given
    }
    # Keep only single Tailscale addresses that aren't this PC: ranges and home addresses are dropped.
    return @(ConvertTo-AddressList -Address $CurrentWhitelist |
            Where-Object { (Test-TailscaleIPv4 -Address $_) -and $_ -ne $OwnIp })
}

function Get-WhitelistChange {
    <#
    .SYNOPSIS
    What a run without -ControllerIp does to the entries it can't keep (not one Tailscale address, or this PC's own).
    With controllers kept, the whitelist is rewritten to just those, so the others are removed. With none kept,
    direct IP access is turned off and the whitelist isn't rewritten, so the others stay in RustDesk.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$CurrentWhitelist = '', [AllowEmptyCollection()][string[]]$Kept = @())
    $notKept = @(ConvertTo-AddressList -Address $CurrentWhitelist | Where-Object { @($Kept) -notcontains $_ })
    return [pscustomobject]@{
        NotKept = $notKept
        Removed = ($notKept.Count -gt 0 -and @($Kept).Count -gt 0)
    }
}

function Get-HostOption {
    <#
    .SYNOPSIS
    The RustDesk settings a locked-down host needs, as an ordered list of key and value (names as in the RustDesk
    version pinned in Setting).
    .DESCRIPTION
    With controllers, direct IP access is on and only they are whitelisted. Without, it is off, and the whitelist is
    left as it is: an empty whitelist would let every device on the Tailscale network try a password, and
    Get-HostSettingFinding fails any entry that isn't a single Tailscale address, so nothing is left there unseen.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowEmptyCollection()][string[]]$ControllerIp = @())

    $ips = @(Resolve-ControllerIp -ControllerIp $ControllerIp)
    $options = [ordered]@{
        # Never register with RustDesk's public ID and relay servers: connect by Tailscale address only.
        'custom-rendezvous-server' = '127.0.0.1'
        'relay-server'             = '127.0.0.1'
        # Only the permanent password works, and a session starts on the password (and two-factor code) alone,
        # so nobody needs to be at the host to click Accept.
        'verification-method'      = 'use-permanent-password'
        'approve-mode'             = 'password'
        # Stop answering LAN discovery on UDP 21119.
        'enable-lan-discovery'     = 'N'
    }
    if ($ips.Count -gt 0) {
        $options['whitelist'] = ($ips -join ',')
        $options['direct-server'] = 'Y'
    } else {
        $options['direct-server'] = 'N'
    }
    return $options
}

function Get-HostOptionKey {
    <# .SYNOPSIS Every RustDesk setting the host checks: the ones Get-HostOption sets, plus the whitelist. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @(@('whitelist') + @((Get-HostOption).Keys) | Select-Object -Unique)
}

function Test-OptionValue {
    <#
    .SYNOPSIS
    True when RustDesk's reported value means the wanted one. RustDesk drops a setting that equals its default, so
    an empty value counts as 'N' for direct-server (off by default).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Key, [AllowEmptyString()][string]$Want, [AllowEmptyString()][AllowNull()][string]$Have)

    $h = if ($null -eq $Have) { '' } else { $Have.Trim() }
    if ($Key -eq 'whitelist') {
        $a = @(ConvertTo-AddressList -Address $Want | Sort-Object)
        $b = @(ConvertTo-AddressList -Address $h | Sort-Object)
        return (($a -join ',') -eq ($b -join ','))
    }
    if ($h -eq $Want) { return $true }
    return ($Key -eq 'direct-server' -and $Want -eq 'N' -and $h -eq '')
}

function Get-OptionFinding {
    <#
    .SYNOPSIS
    Compares RustDesk's current settings (key to value, as RustDesk reports them) with the wanted ones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Wanted,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Actual
    )
    foreach ($key in $Wanted.Keys) {
        $have = if ($Actual.Contains($key) -and $null -ne $Actual[$key]) { "$($Actual[$key])".Trim() } else { '' }
        [pscustomobject]@{
            Check  = "RustDesk setting $key"
            Pass   = (Test-OptionValue -Key $key -Want $Wanted[$key] -Have $have)
            Detail = "want '$($Wanted[$key])', have '$have'"
        }
    }
}

function Get-HostSettingFinding {
    <#
    .SYNOPSIS
    Checks RustDesk's current settings on the host. Given controllers must be valid and exactly whitelisted; without
    them, the current whitelist is judged on its own. Every whitelist entry must be a single Tailscale address that
    isn't this PC, even while direct IP access is off, so turning it on later can't bring back a range. Direct IP
    access on with an empty whitelist fails.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$ControllerIp = @(),
        [Parameter(Mandatory)][System.Collections.IDictionary]$Current,
        [AllowEmptyString()][string]$OwnIp = ''
    )

    $given = @(ConvertTo-AddressList -Address $ControllerIp)
    $whitelist = if ($Current.Contains('whitelist')) { "$($Current['whitelist'])" } else { '' }
    $listed = @(ConvertTo-AddressList -Address $whitelist)
    $directOn = (Test-OptionValue -Key 'direct-server' -Want 'Y' -Have "$($Current['direct-server'])")

    $results = @()
    $results += Get-AddressFinding -Address $given -What 'Given controller address'
    if ($directOn) {
        $results += [pscustomobject]@{
            Check  = 'Whitelist is not empty while direct IP access is on'
            Pass   = ($listed.Count -gt 0)
            Detail = 'an empty whitelist lets every Tailscale device try a password'
        }
    }
    $results += Get-AddressFinding -Address $listed -What 'Whitelist entry'
    if ($OwnIp -and ($listed -contains $OwnIp)) {
        $results += [pscustomobject]@{
            Check  = "Whitelist doesn't include this PC's own address"
            Pass   = $false
            Detail = "remove ${OwnIp}; whitelist only the controllers"
        }
    }
    $validGiven = @($given | Where-Object { Test-TailscaleIPv4 -Address $_ })
    # The wanted settings come from the given controllers, or from the valid entries already whitelisted.
    $basis = if ($given.Count -gt 0) { $validGiven } else { @($listed | Where-Object { Test-TailscaleIPv4 -Address $_ }) }
    $results += Get-OptionFinding -Wanted (Get-HostOption -ControllerIp $basis) -Actual $Current
    return $results
}

function Select-ReleaseAsset {
    <#
    .SYNOPSIS
    Finds the pinned installer in a GitHub release (the object GitHub's releases API returns) and checks it against
    the pinned name, address and SHA-256. GitHub's own digest, when present, must agree too.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)][string]$Sha256
    )

    $asset = @($Release.assets | Where-Object { $_.name -eq $AssetName }) | Select-Object -First 1
    if (-not $asset) { throw "Release $($Release.tag_name) has no file named $AssetName." }

    $repo = $script:Setting.RustDeskRepo
    $prefix = "https://github.com/$repo/releases/download/"
    if (-not "$($asset.browser_download_url)".StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw "The download address for $AssetName isn't on github.com/$repo. Refusing to use it."
    }
    if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) {
        if ("$($asset.digest)".ToLowerInvariant() -ne "sha256:$($Sha256.ToLowerInvariant())") {
            throw "GitHub's SHA-256 for $AssetName differs from the pinned one. Refusing to install."
        }
    }
    return [pscustomobject]@{ Name = $asset.name; Url = $asset.browser_download_url; Sha256 = $Sha256.ToLowerInvariant() }
}

function Test-PortSpecCover {
    <#
    .SYNOPSIS
    True when a firewall rule's LocalPort entry covers the port: 'Any', the port itself, or a range like 21000-22000.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Spec, [int]$Port = $script:Setting.DirectPort)

    $t = $Spec.Trim()
    if ($t -eq 'Any' -or $t -eq "$Port") { return $true }
    if ($t -match '^([0-9]{1,5})-([0-9]{1,5})\z') { return ([int]$Matches[1] -le $Port -and $Port -le [int]$Matches[2]) }
    return $false
}

function Test-AllowRule {
    <#
    .SYNOPSIS
    True for an enabled Allow rule, in the given direction when one is named. Reads Action, Enabled and Direction,
    as Get-NetFirewallRule returns them.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Rule, [ValidateSet('', 'Inbound', 'Outbound')][string]$Direction = '')
    if ("$($Rule.Action)" -ne 'Allow' -or "$($Rule.Enabled)" -ne 'True') { return $false }
    return (-not $Direction -or "$($Rule.Direction)" -eq $Direction)
}

function Test-PortFilterMatch {
    <#
    .SYNOPSIS
    True when a port filter (as Get-NetFirewallPortFilter returns it) lets in TCP on the port: protocol TCP or Any,
    and a LocalPort entry that covers it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Filter, [int]$Port = $script:Setting.DirectPort)
    if ("$($Filter.Protocol)" -notin @('TCP', 'Any')) { return $false }
    return (@(@($Filter.LocalPort) | Where-Object { Test-PortSpecCover -Spec "$_" -Port $Port }).Count -gt 0)
}

function Test-ApplicationFilter {
    <#
    .SYNOPSIS
    True when a rule's application filter (as Get-NetFirewallApplicationFilter returns it) is for RustDesk's program
    (-Program RustDesk), or for no program in particular, so it lets any program in (-Program Any).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Filter, [Parameter(Mandatory)][ValidateSet('RustDesk', 'Any')][string]$Program)
    $have = if ($null -eq $Filter) { '' } else { "$($Filter.Program)" }
    if ($Program -eq 'Any') { return ($have -eq 'Any') }
    return ($have -like '*\rustdesk.exe')
}

function Test-HomeIPv4 {
    <#
    .SYNOPSIS
    True for one IPv4 address in a private home network range: 10.x, 172.16.x to 172.31.x, or 192.168.x. Anything
    else (a Tailscale, loopback or public address) wouldn't test the host's home network path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)
    if (-not (Test-IPv4 -Address $Address)) { return $false }
    $p = $Address.Split('.') | ForEach-Object { [int]$_ }
    return ($p[0] -eq 10 -or ($p[0] -eq 172 -and $p[1] -ge 16 -and $p[1] -le 31) -or ($p[0] -eq 192 -and $p[1] -eq 168))
}

function Get-FirewallProfileFinding {
    <#
    .SYNOPSIS
    Two results per firewall profile (as Get-NetFirewallProfile returns them): the firewall is on, and connections
    nobody ruled on are blocked. With Allow as the default, they get in and the Tailscale limit means nothing.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$FirewallProfile = @())
    if (@($FirewallProfile).Count -eq 0) {
        [pscustomobject]@{ Check = 'Windows Firewall profiles were read'; Pass = $false; Detail = 'none found' }
    }
    foreach ($p in @($FirewallProfile)) {
        [pscustomobject]@{
            Check  = "Windows Firewall is on for the $($p.Name) profile"
            Pass   = ("$($p.Enabled)" -eq 'True')
            Detail = "Enabled: $($p.Enabled)"
        }
        [pscustomobject]@{
            Check  = "Windows Firewall blocks unasked-for connections on the $($p.Name) profile"
            Pass   = ("$($p.DefaultInboundAction)" -eq 'Block')
            Detail = "DefaultInboundAction: $($p.DefaultInboundAction)"
        }
    }
}

function Get-FirewallFinding {
    <#
    .SYNOPSIS
    Checks firewall rules that let RustDesk in. Each rule needs DisplayName, Direction and InterfaceAlias (a string or
    a list). Returns a "rules found" result (unless -SkipCountCheck) plus one per rule.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Rule = @(),
        [string]$AdapterName = $script:Setting.AdapterName,
        [string]$Prefix = '',
        [switch]$SkipCountCheck
    )

    $results = @()
    if (-not $SkipCountCheck) {
        $results += [pscustomobject]@{ Check = 'RustDesk firewall rules exist'; Pass = (@($Rule).Count -gt 0); Detail = "$(@($Rule).Count) found" }
    }
    foreach ($r in @($Rule)) {
        $aliases = @($r.InterfaceAlias)
        $results += [pscustomobject]@{
            Check  = "$($Prefix)Rule '$($r.DisplayName)' ($($r.Direction)) only on $AdapterName"
            Pass   = ($aliases.Count -eq 1 -and "$($aliases[0])" -eq $AdapterName)
            Detail = "InterfaceAlias: $($aliases -join ', ')"
        }
    }
    return $results
}

function Get-PortTestVerdict {
    <# .SYNOPSIS Turns a port test into pass or fail, given whether the port should be reachable. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Reachable,
        [Parameter(Mandatory)][bool]$ShouldBeReachable
    )
    $want = if ($ShouldBeReachable) { 'open' } else { 'closed' }
    $have = if ($Reachable) { 'open' } else { 'closed' }
    return [pscustomobject]@{ Check = $Label; Pass = ($Reachable -eq $ShouldBeReachable); Detail = "want $want, have $have" }
}

function Expand-SystemDrivePath {
    <#
    .SYNOPSIS
    Fills in %SystemDrive% in a registry path with the drive of SystemRoot (such as C:\WINDOWS), not from the
    environment. Throws on any other variable, or when SystemRoot doesn't start with a drive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][AllowEmptyString()][string]$SystemRoot)
    if ($SystemRoot -notmatch '^([A-Za-z]:)\\') { throw "Can't tell the system drive from SystemRoot '$SystemRoot'." }
    $drive = $Matches[1]
    $path = [regex]::Replace($Value, '%SystemDrive%', $drive, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $path -or $path.Contains('%')) { throw "Can't read the ProgramData folder from the registry value '$Value'." }
    return $path
}

function Write-Finding {
    <#
    .SYNOPSIS
    Prints results as PASS or FAIL lines and returns $true when all passed. No results counts as a failure, so a
    check that found nothing to check never reports success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()][object[]]$Finding = @())

    if (@($Finding).Count -eq 0) {
        Write-Host '  FAIL  No checks ran' -ForegroundColor Red
        return $false
    }
    $allPassed = $true
    foreach ($f in @($Finding)) {
        if ($f.Pass) {
            Write-Host ("  PASS  {0}" -f $f.Check) -ForegroundColor Green
        } else {
            $allPassed = $false
            Write-Host ("  FAIL  {0}  ({1})" -f $f.Check, $f.Detail) -ForegroundColor Red
        }
    }
    return $allPassed
}

# --- System reads --------------------------------------------------------------------------------------------

function Get-ProgramFilesPath {
    <#
    .SYNOPSIS
    The 64-bit Program Files folder, read from the machine registry (not from environment variables, which the user
    can change), and correct from 32-bit PowerShell too.
    #>
    [CmdletBinding()]
    param()
    $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -ErrorAction Stop
    if ($key.PSObject.Properties.Name -contains 'ProgramW6432Dir' -and $key.ProgramW6432Dir) { return $key.ProgramW6432Dir }
    return $key.ProgramFilesDir
}

function Get-ProgramDataPath {
    <#
    .SYNOPSIS
    The ProgramData folder, from the machine registry only. Windows stores it as %SystemDrive%\ProgramData, and
    reading it normally fills in %SystemDrive% from the environment; here it is read unexpanded and the drive comes
    from SystemRoot, a plain machine registry value.
    #>
    [CmdletBinding()]
    param()
    $key = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop
    $raw = $key.GetValue('ProgramData', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return (Expand-SystemDrivePath -Value "$raw" -SystemRoot (Get-SystemRootPath))
}

function Get-SystemRootPath {
    <#
    .SYNOPSIS
    The Windows folder (such as C:\WINDOWS), from the machine registry rather than an environment variable. Throws
    unless it starts with a drive, so a path built from it is never looked up from the current folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = "$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).SystemRoot)"
    if ($root -notmatch '^[A-Za-z]:\\') { throw "Can't tell the system drive from SystemRoot '$root'." }
    return $root
}

function Get-System32Exe {
    <# .SYNOPSIS The full path of one of Windows' own programs in System32, so it is never found through PATH. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    # A plain string join: Join-Path would try to resolve the drive, which a test machine may not have.
    return [IO.Path]::Combine((Get-SystemRootPath), 'System32', $Name)
}

function Get-RustDeskExe {
    <# .SYNOPSIS rustdesk.exe from Program Files only, or $null when RustDesk isn't installed. #>
    [CmdletBinding()]
    param()
    $path = Join-Path (Get-ProgramFilesPath) 'RustDesk\rustdesk.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-TailscaleExe {
    <# .SYNOPSIS tailscale.exe from Program Files only: never from PATH, because these scripts run as administrator. #>
    [CmdletBinding()]
    param()
    $path = Join-Path (Get-ProgramFilesPath) 'Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-TailscaleIPv4 {
    <# .SYNOPSIS This PC's Tailscale address, or $null when Tailscale isn't installed or isn't signed in. #>
    [CmdletBinding()]
    param()
    $exe = Get-TailscaleExe
    if (-not $exe) { return $null }
    $out = (& $exe ip -4 2>$null | Out-String).Trim()
    if (Test-TailscaleIPv4 -Address $out) { return $out }
    return $null
}

function Get-RustDeskOption {
    <#
    .SYNOPSIS
    Reads RustDesk settings through its command line. Needs an admin PowerShell and an installed RustDesk. Throws when
    a read fails, so a failed read is never taken for an empty setting.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Key)
    $values = @{}
    foreach ($k in $Key) {
        # Piping makes PowerShell wait for RustDesk, which is a windowed program, and collects its output.
        $out = (& $Exe --option $k | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "RustDesk couldn't read the setting $k (exit code $LASTEXITCODE)." }
        $values[$k] = $out
    }
    return $values
}

function Assert-OnlyNotFound {
    <#
    .SYNOPSIS
    Throws the first error that isn't "not found". Looking up a firewall rule by a name that doesn't exist is normal
    (RustDesk versions name their rules differently); access denied or a firewall service error is not.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$ErrorRecord = @())
    foreach ($e in @($ErrorRecord)) {
        if ($null -ne $e -and "$($e.CategoryInfo.Category)" -ne 'ObjectNotFound') { throw $e }
    }
}

function Get-StoreArg {
    <# .SYNOPSIS Splat for the firewall cmdlets: the given policy store, or none (the local, editable store). #>
    [CmdletBinding()]
    param([string]$PolicyStore = '')
    $a = @{}
    if ($PolicyStore) { $a['PolicyStore'] = $PolicyStore }
    return $a
}

function Get-RustDeskFirewallRule {
    <#
    .SYNOPSIS
    Enabled inbound and outbound Allow rules for RustDesk: by the names its installer uses, plus any rule for its
    program. Block rules are left alone: limiting one to an adapter would only weaken it. -PolicyStore ActiveStore
    reads what Windows actually applies, Group Policy included; the default is the local store the setup changes.
    #>
    [CmdletBinding()]
    param([string]$PolicyStore = '')
    $store = Get-StoreArg -PolicyStore $PolicyStore
    $rules = @()
    foreach ($name in $script:Setting.RuleNames) {
        $lookupError = $null
        $rules += @(Get-NetFirewallRule -DisplayName $name @store -ErrorAction SilentlyContinue -ErrorVariable lookupError)
        Assert-OnlyNotFound -ErrorRecord $lookupError
    }
    # Rules for RustDesk's program under any name, such as ones a RustDesk update renamed.
    foreach ($filter in @(Get-NetFirewallApplicationFilter @store -ErrorAction Stop)) {
        if (Test-ApplicationFilter -Filter $filter -Program RustDesk) { $rules += @(Get-RuleOfFilter -Filter $filter) }
    }
    return @($rules | Where-Object { $_ -and (Test-AllowRule -Rule $_) } | Sort-Object -Property Name -Unique)
}

function Get-PortAllowRule {
    <#
    .SYNOPSIS
    Enabled inbound Allow rules that let any program in on the direct port: no program named, and a port filter that
    covers it (exactly, as a range, or Any) for TCP or any protocol. Such a rule would get around the adapter limit
    unless it is limited to Tailscale too. Rules for one named program (a browser, a game) are left out: they only let
    that program in, and RustDesk's own rules are checked separately.
    #>
    [CmdletBinding()]
    param([string]$PolicyStore = '')
    $store = Get-StoreArg -PolicyStore $PolicyStore
    $found = @()
    foreach ($filter in @(Get-NetFirewallPortFilter @store -ErrorAction Stop)) {
        if (-not (Test-PortFilterMatch -Filter $filter)) { continue }
        foreach ($rule in @(Get-RuleOfFilter -Filter $filter)) {
            if ((Test-AllowRule -Rule $rule -Direction Inbound) -and
                (Test-ApplicationFilter -Filter (Get-ApplicationFilterOfRule -Rule $rule) -Program Any)) { $found += $rule }
        }
    }
    return @($found | Sort-Object -Property Name -Unique)
}

# Thin wrappers for the firewall's links between a rule and its filters, so tests can stand in for them on any system.
function Get-RuleOfFilter {
    <# .SYNOPSIS The firewall rule a port or application filter belongs to. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Filter)
    return @($Filter | Get-NetFirewallRule -ErrorAction Stop)
}

function Get-ApplicationFilterOfRule {
    <# .SYNOPSIS A firewall rule's application filter, which names its program or says Any. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)
    return ($Rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
}

function Get-InterfaceAliasOfRule {
    <# .SYNOPSIS The network adapters a firewall rule applies to, such as Tailscale or Any. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Rule)
    return @(($Rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop).InterfaceAlias)
}

function Get-FirewallRuleState {
    <# .SYNOPSIS The fields Get-FirewallFinding checks, read from live rules. #>
    [CmdletBinding()]
    param([object[]]$Rule = @())
    foreach ($r in @($Rule)) {
        [pscustomobject]@{
            DisplayName    = $r.DisplayName
            Direction      = "$($r.Direction)"
            InterfaceAlias = @(Get-InterfaceAliasOfRule -Rule $r)
        }
    }
}

# --- System changes ------------------------------------------------------------------------------------------

function Install-Tailscale {
    <# .SYNOPSIS Installs the pinned Tailscale with winget. Changes: installs a program. #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-TailscaleExe) { Write-Host 'Tailscale is already installed.'; return }
    # winget can only be found through PATH (Windows installs it as a per-user app alias). Unlike tailscale.exe, there's
    # no fixed path to check; winget itself verifies the installer's hash against its manifest.
    if (-not (Test-WingetPresent)) {
        throw 'winget is missing. Install Tailscale from https://tailscale.com/download, then run this script again.'
    }
    $version = $script:Setting.TailscaleWinget
    if ($PSCmdlet.ShouldProcess("Tailscale $version", 'Install with winget')) {
        $code = Invoke-Winget -Argument @('install', '--id', 'Tailscale.Tailscale', '--exact', '--version', $version,
            '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        if ($code -ne 0) { throw "winget couldn't install Tailscale $version (exit code $code)." }
    }
}

# Thin wrappers around the two programs the system changes run, so tests can stand in for them on any system.
function Test-WingetPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
}

function Invoke-Winget {
    <# .SYNOPSIS Runs winget.exe with the arguments, shows its output, and returns its exit code. #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string[]]$Argument)
    & winget.exe @Argument | Out-Host
    return $LASTEXITCODE
}

function Invoke-IcaclsTool {
    <# .SYNOPSIS Runs icacls.exe with the arguments and returns its exit code and output. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string[]]$Argument)
    $output = (& (Get-System32Exe -Name 'icacls.exe') @Argument 2>&1 | Out-String).Trim()
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function New-PrivateFolder {
    <#
    .SYNOPSIS
    A new, randomly named folder only Administrators and SYSTEM can write to, so a program that isn't running as an
    administrator can't swap the downloaded installer between its check and its launch. Changes: creates a folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $root = Join-Path (Get-ProgramDataPath) 'tailnet-desk'
    $path = Join-Path $root ([guid]::NewGuid().ToString('N'))
    if (-not $PSCmdlet.ShouldProcess($path, 'Create a folder only administrators can write to')) { return $null }

    $trusted = @('S-1-5-32-544', 'S-1-5-18')   # Administrators, SYSTEM
    foreach ($dir in @($root, $path)) {
        if (Test-Path -LiteralPath $dir) {
            # A junction or link here would send the permission change below to another folder: refuse it.
            $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$dir is a link to another folder, not a folder. Delete it and run again."
            }
            # Someone else could have made it first to keep control of it. Only accept one owned by an administrator.
            $owner = (Get-Acl -LiteralPath $dir -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($trusted -notcontains $owner) { throw "$dir already exists and isn't owned by Administrators. Delete it and run again." }
        } else {
            New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
        }
        # Remove inherited permissions; grant full control to Administrators and SYSTEM only.
        $icacls = Invoke-IcaclsTool -Argument @($dir, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
        if ($icacls.ExitCode -ne 0) {
            throw "Couldn't restrict the permissions of $dir (icacls exit code $($icacls.ExitCode)): $($icacls.Output)"
        }
    }
    # Anything planted before the permissions were tightened would still belong to its maker.
    if (@(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop).Count -gt 0) { throw "$path wasn't empty after it was created. Stopping." }
    return $path
}

function Open-LockedFile {
    <#
    .SYNOPSIS
    Opens a file for reading while refusing anyone else write, delete or rename access until the stream is closed.
    #>
    [CmdletBinding()]
    [OutputType([IO.Stream])]
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Install-RustDesk {
    <#
    .SYNOPSIS
    Downloads the pinned RustDesk release from its official GitHub repo into a private folder, checks the file's
    SHA-256 against the pinned one while holding it open so it can't be swapped, and installs it with the RustDesk
    service. Changes: installs a program and a
    service; RustDesk's installer also adds Windows Firewall rules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-RustDeskExe) { Write-Host 'RustDesk is already installed.'; return }
    $s = $script:Setting

    # Windows PowerShell 5.1: GitHub needs TLS 1.2, and the progress bar makes large downloads very slow.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $folder = $null
    $stream = $null
    try {
        $release = Invoke-RestMethod -UseBasicParsing -ErrorAction Stop -Headers @{ 'User-Agent' = 'tailnet-desk' } `
            -Uri "https://api.github.com/repos/$($s.RustDeskRepo)/releases/tags/$($s.RustDeskVersion)"
        $asset = Select-ReleaseAsset -Release $release -AssetName $s.RustDeskAsset -Sha256 $s.RustDeskSha256
        $folder = New-PrivateFolder
        if (-not $folder) { return }
        $file = Join-Path $folder $asset.Name
        Write-Host "Downloading RustDesk $($s.RustDeskVersion) from github.com/$($s.RustDeskRepo) ..."
        Invoke-WebRequest -UseBasicParsing -ErrorAction Stop -Uri $asset.Url -OutFile $file

        # Hold the file open, refusing writes, deletes and renames, from the hash check until the installer exits.
        $stream = Open-LockedFile -Path $file
        $actual = (Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actual -ne $asset.Sha256) {
            throw "The download's SHA-256 doesn't match the pinned one. Nothing was installed."
        }
        Write-Host 'SHA-256 matches the pinned value.'

        if ($PSCmdlet.ShouldProcess("RustDesk $($s.RustDeskVersion)", 'Install with its service')) {
            $p = Start-Process -FilePath $file -ArgumentList '--silent-install' -PassThru -ErrorAction Stop
            $p.WaitForExit()
            if ($p.ExitCode -ne 0) { throw "The RustDesk installer failed (exit code $($p.ExitCode))." }
            # The installer starts the service in the background; give it up to a minute.
            $deadline = (Get-Date).AddSeconds(60)
            $running = $false
            while ((Get-Date) -lt $deadline) {
                $svc = Get-Service -Name $s.ServiceName -ErrorAction SilentlyContinue
                if ($svc -and "$($svc.Status)" -eq 'Running' -and (Get-RustDeskExe)) { $running = $true; break }
                Start-Sleep -Seconds 2
            }
            if (-not (Get-RustDeskExe)) { throw 'RustDesk did not finish installing within a minute.' }
            if (-not $running) { throw "The RustDesk service didn't start within a minute. Restart the PC and run this script again." }
        }
    } finally {
        if ($stream) { $stream.Dispose() }
        $ProgressPreference = $oldProgress
        if ($folder) {
            try { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Couldn't delete the download folder $folder ($($_.Exception.Message)). Delete it by hand." }
        }
    }
}

function Set-RustDeskOption {
    <#
    .SYNOPSIS
    Writes RustDesk settings through its command line (which hands them to the running RustDesk service), then reads
    each one back and throws if it didn't take. Changes: RustDesk's settings.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][System.Collections.IDictionary]$Option)
    foreach ($key in $Option.Keys) {
        if ($PSCmdlet.ShouldProcess("RustDesk setting $key", "Set to '$($Option[$key])'")) {
            $said = (& $Exe --option $key $Option[$key] | Out-String).Trim()
            $now = (Get-RustDeskOption -Exe $Exe -Key @($key))[$key]
            if (-not (Test-OptionValue -Key $key -Want $Option[$key] -Have $now)) {
                throw "RustDesk didn't take the setting $key (wanted '$($Option[$key])', reads '$now'). RustDesk said: $said"
            }
        }
    }
}

function Set-RustDeskFirewallToTailscale {
    <#
    .SYNOPSIS
    Limits RustDesk's Allow rules to one network adapter. Changes: Windows Firewall rules.
    .DESCRIPTION
    A rule whose edge traversal is DeferToUser can't be limited to an adapter, so those switch to Block first.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$AdapterName = $script:Setting.AdapterName)
    if (-not (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)) {
        throw "No network adapter named '$AdapterName'. Is Tailscale installed? Run: Get-NetAdapter"
    }
    $rules = Get-RustDeskFirewallRule
    if (@($rules).Count -eq 0) { throw 'No RustDesk firewall rules found. Is RustDesk installed?' }
    foreach ($r in $rules) {
        if ($PSCmdlet.ShouldProcess("Firewall rule '$($r.DisplayName)' ($($r.Direction))", "Limit to adapter $AdapterName")) {
            if ("$($r.EdgeTraversalPolicy)" -eq 'DeferToUser') { $r | Set-NetFirewallRule -EdgeTraversalPolicy Block -ErrorAction Stop }
            $r | Set-NetFirewallRule -InterfaceAlias $AdapterName -ErrorAction Stop
        }
    }
}

function Set-RustDeskFirewallToAny {
    <#
    .SYNOPSIS
    Undo for Set-RustDeskFirewallToTailscale: RustDesk's Allow rules apply on every adapter again. Edge traversal
    stays Block. Changes: Windows Firewall rules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $rules = Get-RustDeskFirewallRule
    if (@($rules).Count -eq 0) { throw 'No RustDesk firewall rules found, so there was nothing to undo.' }
    foreach ($r in $rules) {
        if ($PSCmdlet.ShouldProcess("Firewall rule '$($r.DisplayName)' ($($r.Direction))", 'Apply on every adapter')) {
            $r | Set-NetFirewallRule -InterfaceAlias Any -ErrorAction Stop
        }
    }
}

Export-ModuleMember -Function *-*
