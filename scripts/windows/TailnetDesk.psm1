# TailnetDesk: shared functions for the Windows host and controller scripts.
# Works on Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII only: Windows PowerShell 5.1 reads
# files without a byte order mark as the system code page, so other characters break.
#
# Pure functions (no system changes) come first and are covered by tests/windows/TailnetDesk.Tests.ps1.
# Functions that change the system come after, and each one says what it changes.

Set-StrictMode -Version 3.0

# --- Constants ---------------------------------------------------------------------------------------------

# RustDesk's direct IP access port (TCP). RustDesk also answers LAN discovery on UDP 21119.
$script:DirectPort = 21118

# The Windows Firewall rule names RustDesk's installer creates. Some PCs have only "RustDesk Service".
$script:RustDeskRuleNames = @('RustDesk Service', 'rustdesk.exe')

# --- Pure functions ------------------------------------------------------------------------------------------

function Test-TailscaleIPv4 {
    <#
    .SYNOPSIS
    True when the text is a single IPv4 address inside Tailscale's range, 100.64.0.0/10 (100.64.0.0 to 100.127.255.255).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)

    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    $parts = $Address.Split('.') | ForEach-Object { [int]$_ }
    foreach ($part in $parts) { if ($part -gt 255) { return $false } }
    return ($parts[0] -eq 100 -and $parts[1] -ge 64 -and $parts[1] -le 127)
}

function Get-HostOption {
    <#
    .SYNOPSIS
    The RustDesk settings a locked-down host needs, as an ordered list of key and value.
    .DESCRIPTION
    Without controller addresses, direct IP access stays off: an empty whitelist would let every device on the
    Tailscale network in. The keys are RustDesk's own option names (RustDesk 1.5.3).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([string[]]$ControllerIp = @())

    $ips = @($ControllerIp | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    foreach ($ip in $ips) {
        if (-not (Test-TailscaleIPv4 -Address $ip)) {
            throw "Not a Tailscale address: '$ip'. Tailscale addresses start with 100. (100.64.0.0 to 100.127.255.255)."
        }
    }

    $options = [ordered]@{
        # Never register with RustDesk's public ID and relay servers: connect by Tailscale address only.
        'custom-rendezvous-server' = '127.0.0.1'
        'relay-server'             = '127.0.0.1'
        # Only the permanent password works, and a session starts on the password alone (nobody needs to click Accept).
        'verification-method'      = 'use-permanent-password'
        'approve-mode'             = 'password'
        # Stop answering LAN discovery on UDP 21119.
        'enable-lan-discovery'     = 'N'
    }
    if ($ips.Count -gt 0) {
        $options['whitelist'] = ($ips -join ',')
        $options['direct-server'] = 'Y'
    }
    return $options
}

function Select-ReleaseAsset {
    <#
    .SYNOPSIS
    Picks the 64-bit Windows installer from a GitHub release (the object GitHub's releases API returns) and its SHA-256.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Release)

    $asset = @($Release.assets | Where-Object { $_.name -match '^rustdesk-[\d.]+-x86_64\.exe$' }) | Select-Object -First 1
    if (-not $asset) { throw "No 64-bit Windows installer (rustdesk-<version>-x86_64.exe) in release $($Release.tag_name)." }

    $digest = $null
    if ($asset.PSObject.Properties.Name -contains 'digest') { $digest = $asset.digest }
    if (-not $digest -or $digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw "GitHub didn't publish a SHA-256 for $($asset.name), so it can't be checked. Install it by hand instead."
    }
    return [pscustomobject]@{
        Name   = $asset.name
        Url    = $asset.browser_download_url
        Sha256 = $Matches[1].ToLowerInvariant()
        Tag    = $Release.tag_name
    }
}

function Get-FirewallFinding {
    <#
    .SYNOPSIS
    Checks RustDesk firewall rules. Each rule needs DisplayName, Enabled, Direction, EdgeTraversalPolicy and
    InterfaceAlias (a string or a list). Returns one result per rule plus one for "rules found".
    #>
    [CmdletBinding()]
    param([object[]]$Rule = @(), [string]$AdapterName = 'Tailscale')

    $results = @()
    $results += [pscustomobject]@{
        Check  = 'RustDesk firewall rules exist'
        Pass   = (@($Rule).Count -gt 0)
        Detail = "$(@($Rule).Count) found"
    }
    foreach ($r in @($Rule)) {
        $aliases = @($r.InterfaceAlias)
        $limited = ($aliases.Count -eq 1 -and "$($aliases[0])" -eq $AdapterName)
        $results += [pscustomobject]@{
            Check  = "Rule '$($r.DisplayName)' ($($r.Direction)) only on $AdapterName"
            Pass   = $limited
            Detail = "InterfaceAlias: $($aliases -join ', ')"
        }
    }
    return $results
}

function Get-OptionFinding {
    <#
    .SYNOPSIS
    Compares RustDesk's current settings (a hashtable of key to value as RustDesk reports them) with the wanted ones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Wanted,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Actual
    )

    $results = @()
    foreach ($key in $Wanted.Keys) {
        $have = ''
        if ($Actual.Contains($key) -and $null -ne $Actual[$key]) { $have = "$($Actual[$key])".Trim() }
        $results += [pscustomobject]@{
            Check  = "RustDesk setting $key"
            Pass   = ($have -eq $Wanted[$key])
            Detail = "want '$($Wanted[$key])', have '$have'"
        }
    }
    return $results
}

function Get-WhitelistFinding {
    <#
    .SYNOPSIS
    Checks RustDesk's whitelist text (comma-separated). Every entry must be a single Tailscale address: a range or
    0.0.0.0 would let in more than the controllers.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Whitelist = '')

    $entries = @($Whitelist.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $results = @()
    $results += [pscustomobject]@{
        Check  = 'Whitelist is not empty'
        Pass   = ($entries.Count -gt 0)
        Detail = 'an empty whitelist lets every Tailscale device try a password'
    }
    foreach ($e in $entries) {
        $results += [pscustomobject]@{
            Check  = "Whitelist entry '$e' is one Tailscale address"
            Pass   = (Test-TailscaleIPv4 -Address $e)
            Detail = 'ranges, 0.0.0.0 and non-Tailscale addresses let in more than your controllers'
        }
    }
    return $results
}

function Get-PortTestVerdict {
    <#
    .SYNOPSIS
    Turns a port test result into pass or fail, given whether the port should be reachable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Reachable,
        [Parameter(Mandatory)][bool]$ShouldBeReachable
    )
    $want = if ($ShouldBeReachable) { 'open' } else { 'closed' }
    $have = if ($Reachable) { 'open' } else { 'closed' }
    return [pscustomobject]@{
        Check  = $Label
        Pass   = ($Reachable -eq $ShouldBeReachable)
        Detail = "want $want, have $have"
    }
}

function Write-Finding {
    <#
    .SYNOPSIS
    Prints results as PASS or FAIL lines and returns $true when all passed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([object[]]$Finding = @())

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

# --- Functions that read the system --------------------------------------------------------------------------

function Test-IsAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RustDeskExe {
    [CmdletBinding()]
    param()
    $path = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-TailscaleExe {
    [CmdletBinding()]
    param()
    $path = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-TailscaleIPv4 {
    <#
    .SYNOPSIS
    This PC's Tailscale address, or $null when Tailscale isn't installed or isn't signed in.
    #>
    [CmdletBinding()]
    param()
    $exe = Get-TailscaleExe
    if (-not $exe) { return $null }
    $out = & $exe ip -4 2>$null | Out-String
    $ip = $out.Trim()
    if (Test-TailscaleIPv4 -Address $ip) { return $ip }
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
    RustDesk's firewall rules: by the names its installer uses, plus any rule whose program is RustDesk.
    #>
    [CmdletBinding()]
    param()
    $rules = @()
    $rules += @(Get-NetFirewallRule -DisplayName $script:RustDeskRuleNames -ErrorAction SilentlyContinue)
    $rules += @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Program -like '*\rustdesk.exe' } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue)
    return @($rules | Where-Object { $_ } | Sort-Object -Property Name -Unique)
}

function Get-FirewallRuleState {
    <#
    .SYNOPSIS
    The fields Get-FirewallFinding checks, read from live rules.
    #>
    [CmdletBinding()]
    param([object[]]$Rule = @())
    foreach ($r in @($Rule)) {
        [pscustomobject]@{
            DisplayName         = $r.DisplayName
            Enabled             = "$($r.Enabled)"
            Direction           = "$($r.Direction)"
            EdgeTraversalPolicy = "$($r.EdgeTraversalPolicy)"
            InterfaceAlias      = @(($r | Get-NetFirewallInterfaceFilter).InterfaceAlias)
        }
    }
}

# --- Functions that change the system ------------------------------------------------------------------------

function Install-Tailscale {
    <#
    .SYNOPSIS
    Installs Tailscale with winget (package Tailscale.Tailscale). Changes: installs a program.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-TailscaleExe) { Write-Host 'Tailscale is already installed.'; return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is missing. Install Tailscale from https://tailscale.com/download, then run this script again.'
    }
    if ($PSCmdlet.ShouldProcess('Tailscale', 'Install with winget')) {
        & winget.exe install --id Tailscale.Tailscale --exact --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget couldn't install Tailscale (exit code $LASTEXITCODE)." }
    }
}

function Install-RustDesk {
    <#
    .SYNOPSIS
    Downloads the newest RustDesk release from its official GitHub repo, checks its SHA-256 against the one GitHub
    publishes, and installs it with the RustDesk service. Changes: installs a program and a service, and RustDesk's
    installer adds Windows Firewall rules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-RustDeskExe) { Write-Host 'RustDesk is already installed.'; return }

    $release = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' `
        -Headers @{ 'User-Agent' = 'tailnet-desk' }
    $asset = Select-ReleaseAsset -Release $release
    $file = Join-Path $env:TEMP $asset.Name
    Write-Host "Downloading RustDesk $($asset.Tag) from github.com/rustdesk/rustdesk ..."
    Invoke-WebRequest -UseBasicParsing -Uri $asset.Url -OutFile $file

    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $asset.Sha256) {
        Remove-Item -LiteralPath $file -Force
        throw "The download's SHA-256 doesn't match the one GitHub published. Deleted it; nothing was installed."
    }
    Write-Host 'SHA-256 matches.'

    if ($PSCmdlet.ShouldProcess('RustDesk', 'Install with its service')) {
        $p = Start-Process -FilePath $file -ArgumentList '--silent-install' -PassThru -Wait
        if ($p.ExitCode -ne 0) { throw "The RustDesk installer failed (exit code $($p.ExitCode))." }
        # The installer starts the service in the background; give it up to a minute.
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running' -and (Get-RustDeskExe)) { break }
            Start-Sleep -Seconds 2
        }
        if (-not (Get-RustDeskExe)) { throw 'RustDesk did not finish installing within a minute.' }
    }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

function Set-RustDeskOption {
    <#
    .SYNOPSIS
    Writes RustDesk settings through its command line, which hands them to the running RustDesk service.
    Changes: RustDesk's settings.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][System.Collections.IDictionary]$Option)
    foreach ($key in $Option.Keys) {
        if ($PSCmdlet.ShouldProcess("RustDesk setting $key", "Set to '$($Option[$key])'")) {
            & $Exe --option $key $Option[$key] | Out-Null
        }
    }
}

function Set-RustDeskFirewallToTailscale {
    <#
    .SYNOPSIS
    Limits every RustDesk firewall rule to one network adapter. Changes: Windows Firewall rules.
    .DESCRIPTION
    A rule whose edge traversal is DeferToUser can't be limited to an adapter, so those switch to Block first.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$AdapterName = 'Tailscale')
    if (-not (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)) {
        throw "No network adapter named '$AdapterName'. Is Tailscale installed? Run: Get-NetAdapter"
    }
    $rules = Get-RustDeskFirewallRule
    if (@($rules).Count -eq 0) { throw 'No RustDesk firewall rules found. Is RustDesk installed?' }
    foreach ($r in $rules) {
        if ($PSCmdlet.ShouldProcess("Firewall rule '$($r.DisplayName)' ($($r.Direction))", "Limit to adapter $AdapterName")) {
            if ("$($r.EdgeTraversalPolicy)" -eq 'DeferToUser') { $r | Set-NetFirewallRule -EdgeTraversalPolicy Block }
            $r | Set-NetFirewallRule -InterfaceAlias $AdapterName
        }
    }
}

function Set-RustDeskFirewallToAny {
    <#
    .SYNOPSIS
    Undo for Set-RustDeskFirewallToTailscale: RustDesk's rules apply on every adapter again. Changes: firewall rules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    foreach ($r in Get-RustDeskFirewallRule) {
        if ($PSCmdlet.ShouldProcess("Firewall rule '$($r.DisplayName)' ($($r.Direction))", 'Apply on every adapter')) {
            $r | Set-NetFirewallRule -InterfaceAlias Any
        }
    }
}

Export-ModuleMember -Function *-*
