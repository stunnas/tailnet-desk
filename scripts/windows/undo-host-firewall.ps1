<#
.SYNOPSIS
Undoes the firewall step of install-host.ps1: RustDesk's Allow rules apply on every network adapter again.

.DESCRIPTION
Run it on the HOST in PowerShell as administrator. Use it if the firewall step causes trouble, or before
uninstalling Tailscale. Edge traversal stays Block, and RustDesk's whitelist, password and two-factor stay as they are.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'tailnet-desk.psm1') -Force
Set-RustDeskFirewallToAny
Write-Host "RustDesk's Allow rules apply on every network adapter again."
