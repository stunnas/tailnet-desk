# tailnet-desk: shared functions for the Windows host and controller scripts.
# Written for Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII only: Windows PowerShell 5.1 reads
# files without a byte order mark as the system code page, so other characters break.
#
# Sections: settings, checks (no system access; tests/windows covers them, plus most system functions with mocks;
# see the README's Status for what isn't),
# system reads, and system changes. Each system change says what it changes. The caller's $ErrorActionPreference
# doesn't reach a module, so system functions pass -ErrorAction Stop to every cmdlet whose failure matters.
#
# Threat model: the scripts run as administrator but trust the signed-in user's account and everything running as it.
# They are run from the user's Downloads folder, so a program running as the user could change them anyway. Windows'
# own tools (icacls, powercfg, msiexec) run from System32, found through the registry. The hardening below protects
# against mistakes and odd setups, not against such a program: system folders come from the machine registry rather
# than environment variables; each downloaded installer sits in an admin-only folder, locked from its SHA-256 and
# publisher signature checks until it exits; and rustdesk.exe and tailscale.exe in Program Files must carry their
# publishers' valid signatures before the scripts rely on them.

Set-StrictMode -Version 3.0

# --- Settings ------------------------------------------------------------------------------------------------
# Versions are pinned and bumped by hand after testing; the SHA-256 is checked before anything runs.

$script:Setting = [pscustomobject]@{
    DirectPort      = 21118                 # RustDesk direct IP access (TCP)
    ListenWaitSeconds = 30                  # how long the check waits for RustDesk to open DirectPort (docs/host-windows.md says 30)
    SignInWaitSeconds = 600                 # how long install-host.ps1 waits for the Tailscale sign-in (docs/host-windows.md says 10 minutes)
    AdapterName     = 'Tailscale'           # Tailscale's network adapter on Windows
    ServiceName     = 'RustDesk'
    RuleNames       = @('RustDesk Service', 'rustdesk.exe')   # names RustDesk's installer gives its firewall rules
    RustDeskRepo    = 'rustdesk/rustdesk'   # the official GitHub repo; downloads come only from its releases
    # Released 2026-11-09. Bump together with RustDeskSha256, then re-test and update the README's Status.
    RustDeskVersion = '1.5.3'
    RustDeskSha256  = '523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249'
    # Tailscale's own Windows installer (MSI) from its package server, released 2026-10-28: the same version the Mac
    # script installs (tests/mac checks it). Bump together with the SHA-256; afterwards Tailscale's updater applies.
    TailscaleVersion   = '1.104.4'
    TailscaleMsiSha256 = '1d12cd8b1d6dbb447da8579b1a5268ae2fc050967bebfaa02e32d2bb645ef6ee'
    TailscalePkgBase   = 'https://pkgs.tailscale.com/stable'
    # Publishers named in the Authenticode certificates (both CN and O) of RustDesk's installer and of tailscale.exe.
    RustDeskSigner  = 'PURSLANE'
    TailscaleSigner = 'Tailscale Inc.'
}
$script:Setting | Add-Member -NotePropertyName RustDeskAsset -NotePropertyValue "rustdesk-$($script:Setting.RustDeskVersion)-x86_64.exe"
$script:Setting | Add-Member -NotePropertyName TailscaleMsi -NotePropertyValue "tailscale-setup-$($script:Setting.TailscaleVersion)-amd64.msi"

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

function Get-SubjectField {
    <#
    .SYNOPSIS
    One field (such as CN or O) of a certificate subject as Windows writes it ("CN=Name, O=Name, C=SG"), or $null.
    The subject is read one field at a time from the left, so a quoted value ("DigiCert, Inc.") may hold commas, and
    text inside another field's quotes is never taken for a field. A field that appears twice, or a subject that
    can't be read that way, gives $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Subject, [Parameter(Mandatory)][string]$Field)
    $rdn = [regex]'\G\s*([A-Za-z0-9.]+)=("(?:[^"]|"")*"|[^,"]*)\s*(?:,|$)'
    $found = @()
    $pos = 0
    while ($pos -lt $Subject.Length) {
        $m = $rdn.Match($Subject, $pos)
        if (-not $m.Success -or $m.Length -eq 0) { return $null }
        if ($m.Groups[1].Value -ceq $Field) {
            $value = $m.Groups[2].Value
            if ($value.StartsWith('"')) { $value = $value.Substring(1, $value.Length - 2).Replace('""', '"') }
            $found += $value.Trim()
        }
        $pos += $m.Length
    }
    if ($found.Count -ne 1) { return $null }
    return $found[0]
}

function Test-PublisherSignature {
    <#
    .SYNOPSIS
    True when an Authenticode signature (as Get-AuthenticodeSignature returns it) is valid, so Windows trusts its
    certificate chain, and its signing certificate names the publisher in both CN and O.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Signature, [Parameter(Mandatory)][string]$Publisher)
    if (-not $Signature -or "$($Signature.Status)" -ne 'Valid' -or -not $Signature.SignerCertificate) { return $false }
    $subject = "$($Signature.SignerCertificate.Subject)"
    return ((Get-SubjectField -Subject $subject -Field 'CN') -ceq $Publisher -and
        (Get-SubjectField -Subject $subject -Field 'O') -ceq $Publisher)
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
    if ($Program -eq 'Any') {
        # A rule for one Windows app package names it under Package and only lets that app in.
        $package = Get-OptionalProperty -InputObject $Filter -Name Package
        return ($have -eq 'Any' -and ($package -eq '' -or $package -eq 'Any'))
    }
    return ($have -like '*\rustdesk.exe')
}

function Get-OptionalProperty {
    <# .SYNOPSIS A property's value as text, or '' when the object or the property is missing (strict mode would throw). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return '' }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return "$($p.Value)"
}

function Test-TailscaleAddressSpec {
    <#
    .SYNOPSIS
    True when a firewall address entry only covers Tailscale: one Tailscale IPv4 address, Tailscale's whole range
    (100.64.0.0/10), or an IPv6 address or range inside fd7a:115c:a1e0::/48. 'Any' and everything else is false. # check-private-data: allow
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Spec)
    $t = $Spec.Trim()
    if (Test-TailscaleIPv4 -Address $t) { return $true }
    if ($t -eq '100.64.0.0/10' -or $t -eq '100.64.0.0/255.192.0.0') { return $true } # check-private-data: allow
    # IPv6 inside fd7a:115c:a1e0::/48, alone or as a range of /48 or longer. check-private-data: allow
    if ($t -match '^fd7a:115c:a1e0:[0-9a-f:]*(/(4[89]|[5-9][0-9]|1[01][0-9]|12[0-8]))?\z') { return $true } # check-private-data: allow
    return $false
}

function Test-OpenToAnyProgram {
    <#
    .SYNOPSIS
    True when an inbound rule could let any program in from any network: no owner, no program or app package named,
    and not limited to this PC's Tailscale addresses. Takes the rule and its application and address filters, as
    Get-NetFirewallRule and its filter commands return them.
    .DESCRIPTION
    Rules with an Owner (a user's SID) belong to one user's packaged Windows app, such as Xbox or Start, and Windows
    applies them only to that app, never to an ordinary program like RustDesk. Tailscale's own rule (Tailscale-In)
    allows everything, but only to this PC's Tailscale addresses, so it can't open RustDesk to other networks.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Rule, [AllowNull()]$ApplicationFilter, [AllowNull()]$AddressFilter)
    if ((Get-OptionalProperty -InputObject $Rule -Name Owner) -ne '') { return $false }
    if (-not (Test-ApplicationFilter -Filter $ApplicationFilter -Program Any)) { return $false }
    $local = @()
    if ($null -ne $AddressFilter) { $local = @(@($AddressFilter.LocalAddress) | ForEach-Object { "$_" } | Where-Object { $_ -ne '' }) }
    if ($local.Count -gt 0 -and @($local | Where-Object { -not (Test-TailscaleAddressSpec -Spec $_) }).Count -eq 0) {
        return $false
    }
    return $true
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
    a list), and may have Protocol. Returns a "rules found" result (unless -SkipCountCheck) plus one per rule. A
    protocol other than Any is named in the check, so rules that share a name (Windows makes a TCP and a UDP rule
    when you allow a program) get different lines.
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
        $kind = "$($r.Direction)"
        $protocol = if ($r.PSObject.Properties['Protocol']) { "$($r.Protocol)" } else { '' }
        if ($protocol -and $protocol -ne 'Any') { $kind += ", $protocol" }
        $results += [pscustomobject]@{
            Check  = "$($Prefix)Rule '$($r.DisplayName)' ($kind) only on $AdapterName"
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

function Get-FileSignature {
    <# .SYNOPSIS A file's Authenticode signature, as Get-AuthenticodeSignature returns it. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
}

function Get-SignatureFinding {
    <# .SYNOPSIS A check result: does the program at Path carry its publisher's valid Authenticode signature? #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Detail
    )
    try { $pass = Test-PublisherSignature -Signature (Get-FileSignature -Path $Path) -Publisher $Publisher }
    catch {
        $pass = $false
        $Detail = "couldn't read its signature ($($_.Exception.Message)); $Detail"
    }
    return [pscustomobject]@{ Check = "$Name is signed by its publisher ($Publisher)"; Pass = $pass; Detail = $Detail }
}

function Get-TailscaleIPv4 {
    <#
    .SYNOPSIS
    This PC's Tailscale address, or $null when Tailscale isn't installed or isn't signed in. tailscale.exe is only run
    when it carries Tailscale's valid signature; otherwise this gives $null too. The scripts that call it also report
    that signature check (Get-SignatureFinding), so the user sees why.
    #>
    [CmdletBinding()]
    param()
    $exe = Get-TailscaleExe
    if (-not $exe) { return $null }
    $signed = Get-SignatureFinding -Name 'Tailscale' -Path $exe -Publisher $script:Setting.TailscaleSigner -Detail 'not run'
    if (-not $signed.Pass) { return $null }
    $out = (& $exe ip -4 2>$null | Out-String).Trim()
    if (Test-TailscaleIPv4 -Address $out) { return $out }
    return $null
}

function Wait-TailscaleIPv4 {
    <#
    .SYNOPSIS
    This PC's Tailscale address, waiting up to TimeoutSeconds for you to sign in to Tailscale, or $null when the time
    runs out. Says once how to sign in, then looks again every 3 seconds.
    #>
    [CmdletBinding()]
    param([ValidateRange(0, 3600)][int]$TimeoutSeconds = $script:Setting.SignInWaitSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $said = $false
    while ($true) {
        $ip = Get-TailscaleIPv4
        if ($ip) { return $ip }
        if ((Get-Date) -ge $deadline) { return $null }
        if (-not $said) {
            $minutes = [int][math]::Ceiling($TimeoutSeconds / 60)
            $unit = if ($minutes -eq 1) { 'minute' } else { 'minutes' }
            Write-Host 'Tailscale is installed but not signed in (or not running).' -ForegroundColor Yellow
            Write-Host 'Click the Tailscale icon in the system tray (near the clock), choose Log in, and sign in. If the icon'
            Write-Host "isn't there, open Tailscale from the Start menu first."
            Write-Host "Waiting up to $minutes $unit for the sign-in. The script goes on by itself once you're signed in."
            $said = $true
        }
        Start-Sleep -Seconds 3
    }
}

function Read-ControllerIp {
    <#
    .SYNOPSIS
    Asks for the controllers' Tailscale addresses, comma-separated, and asks again until they pass the same checks as
    -ControllerIp (Resolve-ControllerIp). Pressing Enter gives none, which keeps the controllers already whitelisted
    (-Kept) or, with none, leaves direct IP access off.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyString()][string]$OwnIp = '',
        [AllowEmptyCollection()][string[]]$Kept = @()
    )
    $kept = @($Kept)
    if ($kept.Count -gt 0) {
        Write-Host "Controllers already on the whitelist: $($kept -join ', ')"
        $prompt = 'Press Enter to keep them, or type the controller addresses to use instead'
        $enter = 'press Enter to keep them'
    } else {
        Write-Host "The controller's address is its 100.x address in the Tailscale admin console (not this PC's)."
        $prompt = "Type the controller's Tailscale address, or press Enter to skip for now"
        $enter = 'press Enter to skip'
    }
    while ($true) {
        $answer = @(ConvertTo-AddressList -Address (Read-Host -Prompt $prompt))
        if ($answer.Count -eq 0) { return @() }
        try { return (Resolve-ControllerIp -ControllerIp $answer -OwnIp $OwnIp) }
        catch { Write-Host "  $($_.Exception.Message) Type it again, or $enter." -ForegroundColor Yellow }
    }
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

function Test-RustDeskListening {
    <#
    .SYNOPSIS
    Whether something listens on RustDesk's direct IP access port, waiting up to TimeoutSeconds: RustDesk opens the
    port a few seconds after direct IP access is turned on, so a check straight after setting it would fail.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [int]$Port = $script:Setting.DirectPort,
        [ValidateRange(0, 300)][int]$TimeoutSeconds = $script:Setting.ListenWaitSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $said = $false
    while ($true) {
        # Nothing listening is reported as "not found"; any other error (access denied, a CIM failure) is thrown, so
        # it isn't taken for a closed port.
        $found = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue -ErrorVariable lookupError)
        Assert-OnlyNotFound -ErrorRecord $lookupError
        if ($found.Count -gt 0) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        if (-not $said) {
            Write-Host "  Waiting up to $TimeoutSeconds seconds for RustDesk to listen on TCP $Port ..."
            $said = $true
        }
        Start-Sleep -Seconds 2
    }
}

function Get-ListeningFinding {
    <# .SYNOPSIS A check result: does RustDesk listen on its direct IP access port, waiting as Test-RustDeskListening does? #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int]$Port = $script:Setting.DirectPort,
        [ValidateRange(0, 300)][int]$TimeoutSeconds = $script:Setting.ListenWaitSeconds
    )
    $detail = "nothing listening after $TimeoutSeconds seconds"
    try { $pass = Test-RustDeskListening -Port $Port -TimeoutSeconds $TimeoutSeconds }
    catch {
        $pass = $false
        $detail = "couldn't read the listening ports ($($_.Exception.Message))"
    }
    return [pscustomobject]@{ Check = "RustDesk listens on TCP $Port"; Pass = $pass; Detail = $detail }
}

function Assert-OnlyNotFound {
    <#
    .SYNOPSIS
    Throws the first error that isn't "not found". A lookup that finds nothing is normal (a firewall rule name another
    RustDesk version uses, a port nothing listens on yet); access denied or a service error is not.
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
    Enabled inbound Allow rules that let any program in on the direct port: a port filter that covers it (exactly, as
    a range, or Any) for TCP or any protocol, and open to any program (Test-OpenToAnyProgram). Such a rule would get
    around the adapter limit unless it is limited to Tailscale too. Rules for one named program or app package (a
    browser, a game, a Windows app) are left out: they only let that program in, and RustDesk's own rules are checked
    separately.
    #>
    [CmdletBinding()]
    param([string]$PolicyStore = '')
    $store = Get-StoreArg -PolicyStore $PolicyStore
    $found = @()
    foreach ($filter in @(Get-NetFirewallPortFilter @store -ErrorAction Stop)) {
        if (-not (Test-PortFilterMatch -Filter $filter)) { continue }
        foreach ($rule in @(Get-RuleOfFilter -Filter $filter)) {
            if (-not (Test-AllowRule -Rule $rule -Direction Inbound)) { continue }
            if (Test-OpenToAnyProgram -Rule $rule -ApplicationFilter (Get-ApplicationFilterOfRule -Rule $rule) `
                    -AddressFilter (Get-AddressFilterOfRule -Rule $rule)) { $found += $rule }
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

function Get-AddressFilterOfRule {
    <# .SYNOPSIS A firewall rule's address filter: which local and remote addresses it covers. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)
    return ($Rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
}

function Get-InterfaceAliasOfRule {
    <# .SYNOPSIS The network adapters a firewall rule applies to, such as Tailscale or Any. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Rule)
    return @(($Rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop).InterfaceAlias)
}

function Get-ProtocolOfRule {
    <# .SYNOPSIS A firewall rule's protocol, such as TCP, UDP or Any. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Rule)
    return "$(($Rule | Get-NetFirewallPortFilter -ErrorAction Stop).Protocol)"
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
            Protocol       = Get-ProtocolOfRule -Rule $r
        }
    }
}

# --- System changes ------------------------------------------------------------------------------------------

function Use-Tls12 {
    <#
    .SYNOPSIS
    Windows PowerShell 5.1: turns on TLS 1.2, which GitHub and Tailscale's package server need. Changes: this
    PowerShell session's TLS setting.
    #>
    [CmdletBinding()]
    param()
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
}

function Assert-PublisherSignature {
    <# .SYNOPSIS Throws the message unless the file carries the publisher's valid Authenticode signature. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not (Test-PublisherSignature -Signature (Get-FileSignature -Path $Path) -Publisher $Publisher)) { throw $Message }
}

function Invoke-CheckedInstaller {
    <#
    .SYNOPSIS
    Downloads an installer into a new admin-only folder and holds it open, refusing writes, deletes and renames, so it
    can't be swapped. Checks its SHA-256 against the pinned one and its publisher's Authenticode signature, then runs
    the script block with the file's path while it is still held. Deletes the folder afterwards, also on failure.
    Changes: whatever the script block installs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Install
    )
    # The progress bar makes large downloads very slow in Windows PowerShell 5.1.
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $folder = $null
    $stream = $null
    try {
        $folder = New-PrivateFolder
        if (-not $folder) { return }
        $file = Join-Path $folder $FileName
        Write-Host "Downloading $Name from $(([uri]$Url).Host) ..."
        Invoke-WebRequest -UseBasicParsing -ErrorAction Stop -Uri $Url -OutFile $file

        $stream = Open-LockedFile -Path $file
        $actual = (Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            throw "The download's SHA-256 doesn't match the pinned one. Nothing was installed."
        }
        Write-Host 'SHA-256 matches the pinned value.'
        Assert-PublisherSignature -Path $file -Publisher $Publisher `
            -Message "The download isn't validly signed by its publisher ($Publisher). Nothing was installed."
        Write-Host "Its signature is valid ($Publisher)."

        if ($PSCmdlet.ShouldProcess($Name, 'Install')) { & $Install $file }
    } finally {
        if ($stream) { $stream.Dispose() }
        $ProgressPreference = $oldProgress
        if ($folder) {
            try { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Couldn't delete the download folder $folder ($($_.Exception.Message)). Delete it by hand." }
        }
    }
}

function Install-Tailscale {
    <#
    .SYNOPSIS
    Installs the pinned Tailscale from its own Windows installer (MSI) on Tailscale's package server, after checking
    the file's SHA-256 and its publisher signature, then checks the installed tailscale.exe's signature. An existing
    Tailscale is kept, once its tailscale.exe passes the signature check. Changes: installs a program.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $s = $script:Setting
    $installed = Get-TailscaleExe
    if ($installed) {
        Assert-PublisherSignature -Path $installed -Publisher $s.TailscaleSigner `
            -Message "tailscale.exe in Program Files isn't validly signed by Tailscale ($($s.TailscaleSigner)). Uninstall Tailscale (Settings, Apps) and run this script again."
        Write-Host 'Tailscale is already installed.'
        return
    }
    Use-Tls12
    Invoke-CheckedInstaller -Url "$($s.TailscalePkgBase)/$($s.TailscaleMsi)" -FileName $s.TailscaleMsi `
        -Sha256 $s.TailscaleMsiSha256 -Publisher $s.TailscaleSigner -Name "Tailscale $($s.TailscaleVersion)" -Install {
        param($file)
        $p = Start-Process -FilePath (Get-System32Exe -Name 'msiexec.exe') -ArgumentList @('/i', "`"$file`"", '/quiet', '/norestart') `
            -PassThru -ErrorAction Stop
        $p.WaitForExit()
        # 3010: installed, and Windows wants a restart to finish.
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Tailscale's installer failed (exit code $($p.ExitCode))." }
        $exe = Get-TailscaleExe
        if (-not $exe) { throw "Tailscale's installer finished, but tailscale.exe isn't in Program Files. Restart the PC and run this script again." }
        Assert-PublisherSignature -Path $exe -Publisher $s.TailscaleSigner `
            -Message "The installed tailscale.exe isn't validly signed by Tailscale ($($s.TailscaleSigner)). Uninstall Tailscale and run this script again."
        if ($p.ExitCode -eq 3010) { Write-Host 'Windows asks for a restart to finish installing Tailscale.' }
    }
}

# Thin wrapper around a program the system changes run, so tests can stand in for it on any system.
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
    Downloads the pinned RustDesk release from its official GitHub repo, checks the file's SHA-256 against the pinned
    one and its publisher signature while holding it so it can't be swapped, and installs it with the RustDesk
    service. An existing RustDesk is kept, once its rustdesk.exe passes the signature check. Changes: installs a
    program and a service; RustDesk's installer also adds Windows Firewall rules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $s = $script:Setting
    $installed = Get-RustDeskExe
    if ($installed) {
        Assert-PublisherSignature -Path $installed -Publisher $s.RustDeskSigner `
            -Message "rustdesk.exe in Program Files isn't validly signed by RustDesk's publisher ($($s.RustDeskSigner)). Uninstall RustDesk (Settings, Apps) and run this script again: it then installs RustDesk's own."
        Write-Host 'RustDesk is already installed.'
        return
    }
    Use-Tls12
    $release = Invoke-RestMethod -UseBasicParsing -ErrorAction Stop -Headers @{ 'User-Agent' = 'tailnet-desk' } `
        -Uri "https://api.github.com/repos/$($s.RustDeskRepo)/releases/tags/$($s.RustDeskVersion)"
    $asset = Select-ReleaseAsset -Release $release -AssetName $s.RustDeskAsset -Sha256 $s.RustDeskSha256
    Invoke-CheckedInstaller -Url $asset.Url -FileName $asset.Name -Sha256 $asset.Sha256 -Publisher $s.RustDeskSigner `
        -Name "RustDesk $($s.RustDeskVersion)" -Install {
        param($file)
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
        $exe = Get-RustDeskExe
        if (-not $exe) { throw 'RustDesk did not finish installing within a minute.' }
        if (-not $running) { throw "The RustDesk service didn't start within a minute. Restart the PC and run this script again." }
        Assert-PublisherSignature -Path $exe -Publisher $s.RustDeskSigner `
            -Message "The installed rustdesk.exe isn't validly signed by RustDesk's publisher ($($s.RustDeskSigner)). Uninstall RustDesk and run this script again."
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
