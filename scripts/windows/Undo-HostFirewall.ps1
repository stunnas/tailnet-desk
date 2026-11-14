<#
.SYNOPSIS
Undoes the firewall step of Install-Host.ps1: RustDesk's firewall rules apply on every network adapter again.

.DESCRIPTION
Run it on the HOST in PowerShell as administrator. Use it if the firewall step causes trouble, or before
uninstalling Tailscale. RustDesk's whitelist, password and two-factor stay as they are.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TailnetDesk.psm1') -Force
Set-RustDeskFirewallToAny
Write-Host 'RustDesk firewall rules apply on every network adapter again.'
