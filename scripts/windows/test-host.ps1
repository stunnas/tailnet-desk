<#
.SYNOPSIS
Checks that this Windows PC is set up as a locked-down RustDesk host. Changes nothing.

.DESCRIPTION
Run it on the HOST in PowerShell as administrator (RustDesk only shows its settings to an administrator).
Prints PASS or FAIL for each check and exits with 1 if anything failed. Each FAIL line is explained in
docs/host-windows.md, "When something goes wrong".

It can't see the password or two-factor settings; check those in RustDesk itself.

.PARAMETER ControllerIp
The Tailscale addresses that should be whitelisted. Leave it out to judge whatever the whitelist holds.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string[]]$ControllerIp = @())

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'tailnet-desk.psm1') -Force
$setting = Get-TailnetDeskSetting

$findings = @()

# Tailscale
$tsIp = Get-TailscaleIPv4
$findings += [pscustomobject]@{ Check = 'Tailscale is signed in'; Pass = [bool]$tsIp; Detail = 'no Tailscale address' }
$adapter = Get-NetAdapter -Name $setting.AdapterName -ErrorAction SilentlyContinue
$findings += [pscustomobject]@{ Check = "Network adapter '$($setting.AdapterName)' exists"; Pass = [bool]$adapter; Detail = 'run Get-NetAdapter' }

# RustDesk
$exe = Get-RustDeskExe
$findings += [pscustomobject]@{ Check = 'RustDesk is installed'; Pass = [bool]$exe; Detail = 'not in Program Files' }
$svc = Get-Service -Name $setting.ServiceName -ErrorAction SilentlyContinue
$findings += [pscustomobject]@{
    Check = 'RustDesk service is running'; Pass = [bool]($svc -and "$($svc.Status)" -eq 'Running'); Detail = "Get-Service $($setting.ServiceName)"
}

if ($exe) {
    $current = Get-RustDeskOption -Exe $exe -Key (Get-HostOptionKey)
    $findings += Get-HostSettingFinding -ControllerIp $ControllerIp -Current $current -OwnIp "$tsIp"

    if (Test-OptionValue -Key 'direct-server' -Want 'Y' -Have $current['direct-server']) {
        $listening = @(Get-NetTCPConnection -LocalPort $setting.DirectPort -State Listen -ErrorAction SilentlyContinue).Count -gt 0
        $findings += [pscustomobject]@{ Check = "RustDesk listens on TCP $($setting.DirectPort)"; Pass = $listening; Detail = 'nothing listening' }
    }
}

# Firewall: what Windows actually applies (ActiveStore), so settings from Group Policy count too.
$findings += Get-FirewallProfileFinding -FirewallProfile @(Get-NetFirewallProfile -PolicyStore ActiveStore)
$findings += Get-FirewallFinding -Rule @(Get-FirewallRuleState -Rule (Get-RustDeskFirewallRule -PolicyStore ActiveStore)) -AdapterName $setting.AdapterName
# Rules that open the port itself (exactly, in a range, or Any) would get around the adapter limit.
$portRules = @(Get-FirewallRuleState -Rule (Get-PortAllowRule -PolicyStore ActiveStore))
$findings += Get-FirewallFinding -Rule $portRules -AdapterName $setting.AdapterName -Prefix 'Port rule: ' -SkipCountCheck

Write-Host ''
Write-Host 'Host checks' -ForegroundColor Cyan
$ok = Write-Finding -Finding $findings
Write-Host ''
if ($ok) {
    Write-Host 'All host checks passed. Now run test-from-controller.ps1 on the controller.' -ForegroundColor Green
    exit 0
}
Write-Host 'Some checks failed. See docs/host-windows.md, "When something goes wrong".' -ForegroundColor Red
exit 1
