<#
.SYNOPSIS
Checks that this Windows PC is set up as a locked-down RustDesk host. Changes nothing.

.DESCRIPTION
Run it on the HOST in PowerShell as administrator (RustDesk only shows its settings to an administrator).
Prints PASS or FAIL for each check and exits with 1 if anything failed. Run it again after every RustDesk update:
an update may reinstall the firewall rules.

It can't see the password or two-factor settings; check those in RustDesk itself.

.PARAMETER ControllerIp
The Tailscale addresses that should be on the whitelist. Leave it out to check whatever the whitelist holds.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string[]]$ControllerIp = @())

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TailnetDesk.psm1') -Force

$findings = @()

# Tailscale
$tsIp = Get-TailscaleIPv4
$findings += [pscustomobject]@{ Check = 'Tailscale is signed in'; Pass = [bool]$tsIp; Detail = 'no Tailscale address' }
$adapter = Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue
$findings += [pscustomobject]@{ Check = "Network adapter 'Tailscale' exists"; Pass = [bool]$adapter; Detail = 'run Get-NetAdapter' }

# RustDesk
$exe = Get-RustDeskExe
$findings += [pscustomobject]@{ Check = 'RustDesk is installed'; Pass = [bool]$exe; Detail = 'not in Program Files' }
$svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
$svcRunning = [bool]($svc -and $svc.Status -eq 'Running')
$findings += [pscustomobject]@{ Check = 'RustDesk service is running'; Pass = $svcRunning; Detail = 'Get-Service RustDesk' }

if ($exe) {
    $current = Get-RustDeskOption -Exe $exe -Key @('whitelist', 'direct-server', 'custom-rendezvous-server',
        'relay-server', 'verification-method', 'approve-mode', 'enable-lan-discovery')

    $ips = @($ControllerIp | Where-Object { $_ })
    if ($ips.Count -eq 0) { $ips = @($current['whitelist'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    if ($current['direct-server'] -eq 'Y') {
        $findings += Get-WhitelistFinding -Whitelist $current['whitelist']
    }
    $validIps = @($ips | Where-Object { Test-TailscaleIPv4 -Address $_ })
    $findings += Get-OptionFinding -Wanted (Get-HostOption -ControllerIp $validIps) -Actual $current

    if ($current['direct-server'] -eq 'Y') {
        $listening = @(Get-NetTCPConnection -LocalPort 21118 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
        $findings += [pscustomobject]@{ Check = 'RustDesk listens on TCP 21118'; Pass = $listening; Detail = 'nothing listening' }
    }
}

# Firewall
$profiles = @(Get-NetFirewallProfile)
foreach ($p in $profiles) {
    $findings += [pscustomobject]@{
        Check  = "Windows Firewall is on for the $($p.Name) profile"
        Pass   = ("$($p.Enabled)" -eq 'True')
        Detail = "Enabled: $($p.Enabled)"
    }
}
$findings += Get-FirewallFinding -Rule @(Get-FirewallRuleState -Rule (Get-RustDeskFirewallRule)) -AdapterName 'Tailscale'

Write-Host ''
Write-Host 'Host checks' -ForegroundColor Cyan
$ok = Write-Finding -Finding $findings
Write-Host ''
if ($ok) {
    Write-Host 'All host checks passed. Now run Test-FromController.ps1 on the controller.' -ForegroundColor Green
    exit 0
}
Write-Host 'Some checks failed. See docs/host-windows.md, "When something goes wrong".' -ForegroundColor Red
exit 1
