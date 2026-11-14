# TailnetDesk: shared functions for the Windows host and controller scripts.
# Written for Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII only: Windows PowerShell 5.1 reads
# files without a byte order mark as the system code page, so other characters break.
#
# Sections: settings, checks (no system access, tested in tests/windows on Linux and Windows), system reads,
# and system changes. Each system change says what it changes. System functions stop on the first error.

Set-StrictMode -Version 3.0

# --- Settings ------------------------------------------------------------------------------------------------
# Versions are pinned and bumped by hand after testing; the SHA-256 is checked before anything runs.

$script:Setting = [pscustomobject]@{
    DirectPort      = 21118                 # RustDesk direct IP access (TCP)
    AdapterName     = 'Tailscale'           # Tailscale's network adapter on Windows
    ServiceName     = 'RustDesk'
    RuleNames       = @('RustDesk Service', 'rustdesk.exe')   # names RustDesk's installer gives its firewall rules
    RustDeskVersion = '1.5.3'
    RustDeskAsset   = 'rustdesk-1.5.3-x86_64.exe'
    RustDeskSha256  = '523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249'
    TailscaleWinget = '1.104.4'             # winget package Tailscale.Tailscale; Tailscale updates itself afterwards
}

function Get-TailnetDeskSetting {
    <# .SYNOPSIS The shared settings: port, adapter and service names, and pinned versions. #>
    [CmdletBinding()]
    param()
    return $script:Setting
}

# --- Checks (no system access) -------------------------------------------------------------------------------

function Test-TailscaleIPv4 {
    <#
    .SYNOPSIS
    True when the text is exactly one IPv4 address inside Tailscale's range, 100.64.0.0/10 (100.64.0.0 to
    100.127.255.255), written without leading zeros.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)

    # \z, not $: $ would also accept a trailing newline. [0-9], not \d: \d matches non-ASCII digits in .NET.
    if ($Address -notmatch '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}\z') { return $false }
    $parts = $Address.Split('.') | ForEach-Object { [int]$_ }
    foreach ($part in $parts) { if ($part -gt 255) { return $false } }
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
    Which controllers to whitelist: the ones given, or, when none are given, the valid ones already in RustDesk's
    whitelist (so a re-run keeps a working setup). Throws on an invalid given address.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$ControllerIp = @(), [AllowEmptyString()][string]$CurrentWhitelist = '')

    $given = @(ConvertTo-AddressList -Address $ControllerIp)
    if ($given.Count -gt 0) {
        foreach ($ip in $given) {
            if (-not (Test-TailscaleIPv4 -Address $ip)) {
                throw "Not a Tailscale address: '$ip'. Tailscale addresses start with 100. (100.64.0.0 to 100.127.255.255)."
            }
        }
        return $given
    }
    return @(ConvertTo-AddressList -Address $CurrentWhitelist | Where-Object { Test-TailscaleIPv4 -Address $_ })
}

function Get-HostOption {
    <#
    .SYNOPSIS
    The RustDesk settings a locked-down host needs, as an ordered list of key and value (RustDesk 1.5.3 names).
    .DESCRIPTION
    With controllers, direct IP access is on and only they are whitelisted. Without, it is off: an empty whitelist
    would let every device on the Tailscale network try a password.
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
    them, the current whitelist is judged on its own. Direct IP access on with a bad or empty whitelist fails.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$ControllerIp = @(), [Parameter(Mandatory)][System.Collections.IDictionary]$Current)

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
        $results += Get-AddressFinding -Address $listed -What 'Whitelist entry'
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

    $prefix = 'https://github.com/rustdesk/rustdesk/releases/download/'
    if (-not "$($asset.browser_download_url)".StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw "The download address for $AssetName isn't on github.com/rustdesk/rustdesk. Refusing to use it."
    }
    if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) {
        if ("$($asset.digest)".ToLowerInvariant() -ne "sha256:$($Sha256.ToLowerInvariant())") {
            throw "GitHub's SHA-256 for $AssetName differs from the pinned one. Refusing to install."
        }
    }
    return [pscustomobject]@{ Name = $asset.name; Url = $asset.browser_download_url; Sha256 = $Sha256.ToLowerInvariant() }
}

function Get-FirewallFinding {
    <#
    .SYNOPSIS
    Checks firewall rules that let RustDesk in. Each rule needs DisplayName, Direction and InterfaceAlias (a string or
    a list). Returns a "rules found" result plus one per rule.
    #>
    [CmdletBinding()]
    param([object[]]$Rule = @(), [string]$AdapterName = $script:Setting.AdapterName, [string]$Label = 'RustDesk firewall rules exist')

    $results = @()
    $results += [pscustomobject]@{ Check = $Label; Pass = (@($Rule).Count -gt 0); Detail = "$(@($Rule).Count) found" }
    foreach ($r in @($Rule)) {
        $aliases = @($r.InterfaceAlias)
        $results += [pscustomobject]@{
            Check  = "Rule '$($r.DisplayName)' ($($r.Direction)) only on $AdapterName"
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
    <# .SYNOPSIS The 64-bit Program Files folder, even from 32-bit PowerShell. #>
    [CmdletBinding()]
    param()
    if ($env:ProgramW6432) { return $env:ProgramW6432 }
    return $env:ProgramFiles
}

function Get-RustDeskExe {
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
    Reads RustDesk settings through its command line. Needs an admin PowerShell and an installed RustDesk.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Key)
    $values = @{}
    foreach ($k in $Key) {
        # Piping makes PowerShell wait for RustDesk, which is a windowed program, and collects its output.
        $values[$k] = (& $Exe --option $k | Out-String).Trim()
    }
    return $values
}

function Get-RustDeskFirewallRule {
    <#
    .SYNOPSIS
    Enabled inbound and outbound Allow rules for RustDesk: by the names its installer uses, plus any rule for its
    program. Block rules are left alone: limiting one to an adapter would only weaken it.
    #>
    [CmdletBinding()]
    param()
    $rules = @()
    $rules += @(Get-NetFirewallRule -DisplayName $script:Setting.RuleNames -ErrorAction SilentlyContinue)
    $rules += @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Program -like '*\rustdesk.exe' } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue)
    return @($rules | Where-Object { $_ -and "$($_.Action)" -eq 'Allow' -and "$($_.Enabled)" -eq 'True' } |
        Sort-Object -Property Name -Unique)
}

function Get-PortAllowRule {
    <# .SYNOPSIS Enabled inbound Allow rules for the direct port that name a port rather than a program. #>
    [CmdletBinding()]
    param()
    $port = "$($script:Setting.DirectPort)"
    return @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue |
        Where-Object { @($_.LocalPort) -contains $port } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { "$($_.Direction)" -eq 'Inbound' -and "$($_.Action)" -eq 'Allow' -and "$($_.Enabled)" -eq 'True' } |
        Sort-Object -Property Name -Unique)
}

function Get-FirewallRuleState {
    <# .SYNOPSIS The fields Get-FirewallFinding checks, read from live rules. #>
    [CmdletBinding()]
    param([object[]]$Rule = @())
    foreach ($r in @($Rule)) {
        [pscustomobject]@{
            DisplayName    = $r.DisplayName
            Direction      = "$($r.Direction)"
            InterfaceAlias = @(($r | Get-NetFirewallInterfaceFilter).InterfaceAlias)
        }
    }
}

# --- System changes ------------------------------------------------------------------------------------------

function Install-Tailscale {
    <# .SYNOPSIS Installs the pinned Tailscale with winget. Changes: installs a program. #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-TailscaleExe) { Write-Host 'Tailscale is already installed.'; return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is missing. Install Tailscale from https://tailscale.com/download, then run this script again.'
    }
    $version = $script:Setting.TailscaleWinget
    if ($PSCmdlet.ShouldProcess("Tailscale $version", 'Install with winget')) {
        & winget.exe install --id Tailscale.Tailscale --exact --version $version --source winget --silent `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget couldn't install Tailscale $version (exit code $LASTEXITCODE)." }
    }
}

function New-PrivateFolder {
    <#
    .SYNOPSIS
    A new, randomly named folder only Administrators and SYSTEM can write to, so nothing else running as you can
    swap a downloaded installer between its check and its launch. Changes: creates a folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $root = Join-Path $env:ProgramData 'tailnet-desk'
    $path = Join-Path $root ([guid]::NewGuid().ToString('N'))
    if ($PSCmdlet.ShouldProcess($path, 'Create a folder only administrators can write to')) {
        New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        # Remove inherited permissions; grant full control to Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18) only.
        & icacls.exe $path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            throw "Couldn't restrict the download folder's permissions (icacls exit code $LASTEXITCODE)."
        }
    }
    return $path
}

function Install-RustDesk {
    <#
    .SYNOPSIS
    Downloads the pinned RustDesk release from its official GitHub repo into a private folder, checks the file's
    SHA-256 against the pinned one, and installs it with the RustDesk service. Changes: installs a program and a
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
    try {
        $release = Invoke-RestMethod -UseBasicParsing -ErrorAction Stop -Headers @{ 'User-Agent' = 'tailnet-desk' } `
            -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/tags/$($s.RustDeskVersion)"
        $asset = Select-ReleaseAsset -Release $release -AssetName $s.RustDeskAsset -Sha256 $s.RustDeskSha256
        $folder = New-PrivateFolder
        $file = Join-Path $folder $asset.Name
        Write-Host "Downloading RustDesk $($s.RustDeskVersion) from github.com/rustdesk/rustdesk ..."
        Invoke-WebRequest -UseBasicParsing -ErrorAction Stop -Uri $asset.Url -OutFile $file

        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
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
            while ((Get-Date) -lt $deadline) {
                $svc = Get-Service -Name $s.ServiceName -ErrorAction SilentlyContinue
                if ($svc -and "$($svc.Status)" -eq 'Running' -and (Get-RustDeskExe)) { break }
                Start-Sleep -Seconds 2
            }
            if (-not (Get-RustDeskExe)) { throw 'RustDesk did not finish installing within a minute.' }
        }
    } finally {
        $ProgressPreference = $oldProgress
        if ($folder) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
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
    foreach ($r in Get-RustDeskFirewallRule) {
        if ($PSCmdlet.ShouldProcess("Firewall rule '$($r.DisplayName)' ($($r.Direction))", 'Apply on every adapter')) {
            $r | Set-NetFirewallRule -InterfaceAlias Any -ErrorAction Stop
        }
    }
}

Export-ModuleMember -Function *-*
