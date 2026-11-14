<#
.SYNOPSIS
From the CONTROLLER, checks that the host answers over Tailscale and not over the home network. Changes nothing.

.DESCRIPTION
Run it on the controller (the PC you sit at), in a normal PowerShell window. Never run it on the host: Windows
Firewall doesn't filter a PC's connections to its own addresses, so the tests would always pass there.

For the home network test, the controller must be on the same home network as the host.

.PARAMETER HostTailscaleIp
The HOST's Tailscale address (100.x.y.z), from the Tailscale admin console or the end of Install-Host.ps1.

.PARAMETER HostHomeIp
The HOST's home network address, from running ipconfig on the host ("IPv4 Address", often 192.168.x.x).
Leave it out to skip the home network test, for example when you're away from home.

.EXAMPLE
.\Test-FromController.ps1 -HostTailscaleIp 100.64.0.10 -HostHomeIp 192.168.0.10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HostTailscaleIp,
    [string]$HostHomeIp
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TailnetDesk.psm1') -Force
$port = (Get-TailnetDeskSetting).DirectPort

if (-not (Test-TailscaleIPv4 -Address $HostTailscaleIp)) {
    throw "Not a Tailscale address: '$HostTailscaleIp'. It should start with 100."
}
$myIp = Get-TailscaleIPv4
if ($myIp -and $myIp -eq $HostTailscaleIp) {
    throw "That's this PC's own address. Run this on the controller, with the host's address."
}

function Test-Port([string]$Address) {
    # Test-NetConnection prints a warning when the port is closed; that's an expected result here.
    $r = Test-NetConnection -ComputerName $Address -Port $port -WarningAction SilentlyContinue
    return [bool]$r.TcpTestSucceeded
}

$findings = @()
$findings += [pscustomobject]@{ Check = 'This PC is signed in to Tailscale'; Pass = [bool]$myIp; Detail = 'no Tailscale address' }
$findings += Get-PortTestVerdict -Label "Host's Tailscale address answers on $port" `
    -Reachable (Test-Port $HostTailscaleIp) -ShouldBeReachable $true
if ($HostHomeIp) {
    $findings += Get-PortTestVerdict -Label "Host's home address does NOT answer on $port" `
        -Reachable (Test-Port $HostHomeIp) -ShouldBeReachable $false
}

Write-Host ''
Write-Host 'Controller checks' -ForegroundColor Cyan
$ok = Write-Finding -Finding $findings
Write-Host ''
if (-not $HostHomeIp) { Write-Host 'Skipped the home network test (no -HostHomeIp).' -ForegroundColor Yellow }
Write-Host 'Still test by hand: connecting from a device NOT on the whitelist must show "Your ip is blocked by the peer".'
if ($ok) { exit 0 }
exit 1
