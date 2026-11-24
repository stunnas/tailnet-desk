<#
.SYNOPSIS
Sets up this Windows PC as a RustDesk host that only answers over Tailscale.

.DESCRIPTION
Run it on the HOST, the PC that will be controlled, in PowerShell as administrator. It is safe to run again: each
step skips what is already done. Without -ControllerIp it asks for the controllers' addresses in step 4, and
pressing Enter there keeps the controllers already whitelisted.

  1. Installs Tailscale (pinned version) from Tailscale's own installer if it's missing, after checking the file's
     SHA-256 and its publisher signature (Tailscale Inc.), then waits up to 10 minutes for you to sign in.
  2. Installs RustDesk (pinned version) from its official GitHub release after checking the file's SHA-256 and its
     publisher signature (PURSLANE), then stops it using RustDesk's public ID and relay servers. An existing
     Tailscale or RustDesk is kept once its program passes the same signature check.
  3. Limits RustDesk's Windows Firewall rules to the Tailscale adapter. This comes before step 4, so direct IP access
     is never on while the firewall still lets every network in.
  4. Sets RustDesk's security settings: no public ID or relay server, permanent password only, sessions start on the
     password without anyone clicking Accept, no LAN discovery, and direct IP access with only your controllers
     whitelisted (off until there is a controller). Asks for the controllers' addresses unless -ControllerIp gave them.
  5. Sets the PC to never sleep while plugged in (skip with -KeepSleep).
  6. Runs test-host.ps1 and lists what you still do by hand: the password and two-factor.

It never sets or shows a password.

.PARAMETER ControllerIp
The Tailscale address (100.x.y.z) of each device allowed to connect, for example the laptop you'll sit at.
Never this PC's own address. Leave it out and the script asks for it in step 4 instead; give it to run the script
without that question.

.PARAMETER KeepSleep
Don't change the sleep setting.

.EXAMPLE
.\install-host.ps1 -ControllerIp 100.64.0.11
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string[]]$ControllerIp = @(),
    [switch]$KeepSleep
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'tailnet-desk.psm1') -Force
$setting = Get-TailnetDeskSetting

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

# Check the given addresses before changing anything.
$null = Resolve-ControllerIp -ControllerIp $ControllerIp

Write-Step 'Step 1 of 6: Tailscale'
Install-Tailscale
$myIp = Wait-TailscaleIPv4
if (-not $myIp) {
    Write-Host "Tailscale still isn't signed in. Sign in, then run this script again. If Tailscale says it's stopped, restart the PC first." -ForegroundColor Yellow
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
$source = 'from -ControllerIp'
if ($given.Count -eq 0) {
    $kept = @(Resolve-ControllerIp -CurrentWhitelist $current['whitelist'] -OwnIp $myIp)
    $given = @(Read-ControllerIp -OwnIp $myIp -Kept $kept)
    $source = 'typed in'
}
$controllers = @(Resolve-ControllerIp -ControllerIp $given -CurrentWhitelist $current['whitelist'] -OwnIp $myIp)
$options = Get-HostOption -ControllerIp $controllers
if ($controllers.Count -gt 0) {
    if ($given.Count -eq 0) { $source = 'kept from before' }
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
            Write-Host '  They stay in RustDesk until you run this again and type the controller''s address, and the check below fails them.' -ForegroundColor Yellow
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
# Only addresses given or typed on this run are passed on; otherwise the check judges the whitelist on its own.
& (Join-Path $PSScriptRoot 'test-host.ps1') -ControllerIp $given
$checksPassed = ($LASTEXITCODE -eq 0)

Write-Host ''
Write-Host 'Still to do by hand, in RustDesk on this PC (Settings > Security > Unlock security settings):' -ForegroundColor Cyan
Write-Host '  1. Password: if you have not set one yet, click "Set permanent password" (the script already chose'
Write-Host '     "Use permanent password", so RustDesk''s one-time password no longer works).'
Write-Host '     Use a random 20+ character password from your password manager. Never reuse it.'
Write-Host '  2. Two-factor authentication: turn it on and scan the QR code with your authenticator app.'
Write-Host '     Never photograph or share the QR code: it is the secret.'
if ($controllers.Count -eq 0) {
    Write-Host '  3. When the controller is on Tailscale, run .\install-host.ps1 again and type its 100.x address'
    Write-Host '     when it asks.'
}
Write-Host 'On each controller, leave "Remember password" off, and only trust a controller for two-factor if it stays'
Write-Host 'locked: whoever unlocks a trusted controller needs only the password.'
Write-Host ''
Write-Host "The controller connects to this PC's Tailscale address: $myIp"
if (-not $checksPassed) { exit 1 }
exit 0
