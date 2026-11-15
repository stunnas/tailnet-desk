<#
.SYNOPSIS
Sets up this Windows PC as a RustDesk host that only answers over Tailscale.

.DESCRIPTION
Run it on the HOST, the PC that will be controlled, in PowerShell as administrator. It is safe to run again: each
step skips what is already done, and a run without -ControllerIp keeps the controllers already whitelisted.

  1. Installs Tailscale (pinned version, with winget) if it's missing, then stops until you've signed in.
  2. Installs RustDesk (pinned version) from its official GitHub release after checking the file's SHA-256, then
     stops it using RustDesk's public ID and relay servers.
  3. Limits RustDesk's Windows Firewall rules to the Tailscale adapter. This comes before step 4, so direct IP access
     is never on while the firewall still lets every network in.
  4. Sets RustDesk's security settings: no public ID or relay server, permanent password only, sessions start on the
     password without anyone clicking Accept, no LAN discovery, and direct IP access with only your controllers
     whitelisted (off until there is a controller).
  5. Sets the PC to never sleep while plugged in (skip with -KeepSleep).
  6. Runs Test-Host.ps1 and lists what you still do by hand: the password and two-factor.

It never sets or shows a password.

.PARAMETER ControllerIp
The Tailscale address (100.x.y.z) of each device allowed to connect, for example the laptop you'll sit at.
Never this PC's own address. Leave it out on the first run if no controller is on Tailscale yet.

.PARAMETER KeepSleep
Don't change the sleep setting.

.EXAMPLE
.\Install-Host.ps1 -ControllerIp 100.64.0.11
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string[]]$ControllerIp = @(),
    [switch]$KeepSleep
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TailnetDesk.psm1') -Force
$setting = Get-TailnetDeskSetting

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

# Check the given addresses before changing anything.
$null = Resolve-ControllerIp -ControllerIp $ControllerIp

Write-Step 'Step 1 of 6: Tailscale'
Install-Tailscale
$myIp = Get-TailscaleIPv4
if (-not $myIp) {
    Write-Host 'Tailscale is installed but not signed in (or not running).' -ForegroundColor Yellow
    Write-Host 'Click the Tailscale icon in the system tray (near the clock), choose Log in, and sign in.'
    Write-Host 'Then run this script again.'
    exit 2
}
Write-Host "Tailscale is signed in. This PC's (the host's) Tailscale address: $myIp"
$given = @(ConvertTo-AddressList -Address $ControllerIp)
# Refuses this PC's own address before anything else changes.
$null = Resolve-ControllerIp -ControllerIp $given -OwnIp $myIp

Write-Step 'Step 2 of 6: RustDesk'
Install-RustDesk
$exe = Get-RustDeskExe
if (-not $exe) { throw 'RustDesk is not installed.' }
# Stop using RustDesk's public ID and relay servers straight away, so a later step that stops the script doesn't
# leave the PC reachable through them. The other settings wait for step 4, after the firewall.
$servers = [ordered]@{}
foreach ($key in @('custom-rendezvous-server', 'relay-server')) { $servers[$key] = (Get-HostOption)[$key] }
Set-RustDeskOption -Exe $exe -Option $servers
Write-Host "RustDesk no longer uses its public servers."

Write-Step 'Step 3 of 6: Windows Firewall'
Set-RustDeskFirewallToTailscale -AdapterName $setting.AdapterName
Write-Host "RustDesk's firewall rules now apply to the $($setting.AdapterName) adapter only."

Write-Step 'Step 4 of 6: RustDesk security settings'
$current = Get-RustDeskOption -Exe $exe -Key @('whitelist')
$controllers = @(Resolve-ControllerIp -ControllerIp $given -CurrentWhitelist $current['whitelist'] -OwnIp $myIp)
$options = Get-HostOption -ControllerIp $controllers
if ($controllers.Count -gt 0) {
    $source = if ($given.Count -gt 0) { 'from -ControllerIp' } else { 'kept from before' }
    Write-Host "Direct IP access: on. Whitelist ($source): $($options['whitelist'])"
} else {
    Write-Host 'No controller yet, so direct IP access is OFF.' -ForegroundColor Yellow
}
if ($given.Count -eq 0) {
    $change = Get-WhitelistChange -CurrentWhitelist $current['whitelist'] -Kept $controllers
    if ($change.NotKept.Count -gt 0) {
        Write-Host "Not kept: $($change.NotKept -join ', '). Each isn't a single Tailscale address or is this PC's own." -ForegroundColor Yellow
        if ($change.Removed) {
            Write-Host '  They are removed from the whitelist now.' -ForegroundColor Yellow
        } else {
            Write-Host '  They stay in RustDesk until you run this again with -ControllerIp, and the check below fails them.' -ForegroundColor Yellow
        }
    }
}
Set-RustDeskOption -Exe $exe -Option $options

Write-Step 'Step 5 of 6: Sleep'
if ($KeepSleep) {
    Write-Host 'Left unchanged (-KeepSleep).'
} else {
    & (Get-System32Exe -Name 'powercfg.exe') /change standby-timeout-ac 0
    if ($LASTEXITCODE -ne 0) { throw "powercfg failed (exit code $LASTEXITCODE)." }
    Write-Host 'This PC no longer sleeps while plugged in. (The screen can still turn off.)'
}

Write-Step 'Step 6 of 6: Check'
# Only addresses given on this run are passed on; otherwise the check judges the whitelist on its own.
& (Join-Path $PSScriptRoot 'Test-Host.ps1') -ControllerIp $given
$checksPassed = ($LASTEXITCODE -eq 0)

Write-Host ''
Write-Host 'Still to do by hand, in RustDesk on this PC (Settings > Security > Unlock security settings):' -ForegroundColor Cyan
Write-Host '  1. Password: if you have not set one yet, click "Set permanent password" (the script already chose'
Write-Host '     "Use permanent password", so RustDesk''s one-time password no longer works).'
Write-Host '     Use a random 20+ character password from your password manager. Never reuse it.'
Write-Host '  2. Two-factor authentication: turn it on and scan the QR code with your authenticator app.'
Write-Host '     Never photograph or share the QR code: it is the secret.'
Write-Host 'On each controller, leave "Remember password" off and don''t trust the device for two-factor: otherwise anyone'
Write-Host 'who unlocks that controller can connect to this PC without either.'
if ($controllers.Count -eq 0) {
    Write-Host '  3. When the controller is on Tailscale, run this again with its address, for example:'
    Write-Host '     .\Install-Host.ps1 -ControllerIp 100.64.0.11   (use the controller''s real 100.x address)'
}
Write-Host ''
Write-Host "The controller connects to this PC's Tailscale address: $myIp"
if (-not $checksPassed) { exit 1 }
exit 0
