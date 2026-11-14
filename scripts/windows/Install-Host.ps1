<#
.SYNOPSIS
Sets up this Windows PC as a RustDesk host that only answers over Tailscale.

.DESCRIPTION
Run it on the HOST, the PC that will be controlled, in PowerShell as administrator. It is safe to run again: each
step skips what is already done.

  1. Installs Tailscale (winget) if it's missing, then stops until you've signed in.
  2. Installs RustDesk from its official GitHub release after checking the file's SHA-256.
  3. Sets RustDesk's security settings: no public ID or relay server, permanent password only, no LAN discovery,
     and, when you pass -ControllerIp, direct IP access with only those addresses whitelisted.
  4. Limits RustDesk's Windows Firewall rules to the Tailscale adapter.
  5. Sets the PC to never sleep while plugged in.
  6. Runs Test-Host.ps1 and lists what you still do by hand: the password and two-factor.

It never sets or prints a password.

.PARAMETER ControllerIp
The Tailscale address (100.x.y.z) of each PC or phone allowed to connect. Leave it out on the first run if the
controller isn't on Tailscale yet; direct IP access then stays off until you run the script again with it.

.PARAMETER KeepSleep
Don't change the sleep setting.

.EXAMPLE
.\Install-Host.ps1 -ControllerIp 100.64.0.10
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$ControllerIp = @(),
    [switch]$KeepSleep
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TailnetDesk.psm1') -Force

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

# Check the addresses before changing anything.
$options = Get-HostOption -ControllerIp $ControllerIp

Write-Step 'Step 1 of 6: Tailscale'
Install-Tailscale
$myIp = Get-TailscaleIPv4
if (-not $myIp) {
    Write-Host 'Tailscale is installed but not signed in.' -ForegroundColor Yellow
    Write-Host 'Click the Tailscale icon in the system tray (near the clock), choose Log in, and sign in.'
    Write-Host 'Then run this script again.'
    exit 2
}
Write-Host "Tailscale is signed in. This PC's Tailscale address: $myIp"

Write-Step 'Step 2 of 6: RustDesk'
Install-RustDesk
$exe = Get-RustDeskExe
if (-not $exe) {
    if ($WhatIfPreference) { Write-Host 'WhatIf: stopping here, because the steps below need RustDesk installed.'; exit 0 }
    throw 'RustDesk is not installed.'
}

Write-Step 'Step 3 of 6: RustDesk security settings'
if ($options.Contains('whitelist')) {
    Write-Host "Direct IP access: on. Whitelist: $($options['whitelist'])"
} else {
    Write-Host 'No -ControllerIp given, so direct IP access stays OFF for now.' -ForegroundColor Yellow
    Write-Host 'When the controller is on Tailscale, run this script again with -ControllerIp <its 100.x address>.'
}
Set-RustDeskOption -Exe $exe -Option $options

Write-Step 'Step 4 of 6: Windows Firewall'
Set-RustDeskFirewallToTailscale -AdapterName 'Tailscale'
Write-Host 'RustDesk firewall rules now apply to the Tailscale adapter only.'

Write-Step 'Step 5 of 6: Sleep'
if ($KeepSleep) {
    Write-Host 'Left unchanged (-KeepSleep).'
} elseif ($PSCmdlet.ShouldProcess('Power settings', 'Never sleep while plugged in')) {
    & powercfg.exe /change standby-timeout-ac 0
    Write-Host 'This PC no longer sleeps while plugged in. (The screen can still turn off.)'
}

Write-Step 'Step 6 of 6: Check'
& (Join-Path $PSScriptRoot 'Test-Host.ps1') -ControllerIp $ControllerIp
$checksPassed = ($LASTEXITCODE -eq 0)

Write-Host ''
Write-Host 'Still to do by hand, in RustDesk on this PC (Settings > Security > Unlock security settings):' -ForegroundColor Cyan
Write-Host '  1. Password: choose "Use permanent password", then "Set permanent password".'
Write-Host '     Use a random 20+ character password from your password manager. Never reuse it.'
Write-Host '  2. Two-factor authentication: turn it on and scan the QR code with your authenticator app.'
Write-Host '     Never photograph or share the QR code: it is the secret.'
if (-not $options.Contains('whitelist')) {
    Write-Host "  3. When the controller is on Tailscale, run: .\Install-Host.ps1 -ControllerIp <controller's 100.x address>"
}
Write-Host ''
Write-Host "Connect from the controller to this PC's Tailscale address: $myIp"
if (-not $checksPassed) { exit 1 }
