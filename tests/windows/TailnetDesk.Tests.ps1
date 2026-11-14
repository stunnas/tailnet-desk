# Pester 5 tests for the pure functions in scripts/windows/TailnetDesk.psm1. They change nothing on the system,
# so they run on Linux in CI. Run locally: Invoke-Pester -Path tests/windows

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../scripts/windows/TailnetDesk.psm1') -Force
}

Describe 'Test-TailscaleIPv4' {
    It 'accepts addresses inside 100.64.0.0/10: <_>' -ForEach @('100.64.0.1', '100.64.0.10', '100.127.255.254', '100.100.0.1') {
        Test-TailscaleIPv4 -Address $_ | Should -BeTrue
    }
    It 'rejects <_>' -ForEach @('100.63.255.255', '100.128.0.1', '192.168.0.10', '10.0.0.1', '100.64.0.256',
        '100.64.0', '100.64.0.0/10', ' 100.64.0.1', '', 'abc', '0.0.0.0') {
        Test-TailscaleIPv4 -Address $_ | Should -BeFalse
    }
}

Describe 'Get-HostOption' {
    It 'turns on direct IP access and whitelists exactly the controllers' {
        $o = Get-HostOption -ControllerIp @('100.64.0.10', '100.64.0.11')
        $o['direct-server'] | Should -Be 'Y'
        $o['whitelist'] | Should -Be '100.64.0.10,100.64.0.11'
    }
    It 'trims and removes duplicate addresses' {
        (Get-HostOption -ControllerIp @(' 100.64.0.10', '100.64.0.10 ', ''))['whitelist'] | Should -Be '100.64.0.10'
    }
    It 'leaves direct IP access off without controllers, so an empty whitelist never opens the port' {
        $o = Get-HostOption
        $o.Contains('direct-server') | Should -BeFalse
        $o.Contains('whitelist') | Should -BeFalse
    }
    It 'always points the ID and relay servers at this PC and allows only the permanent password' {
        $o = Get-HostOption
        $o['custom-rendezvous-server'] | Should -Be '127.0.0.1'
        $o['relay-server'] | Should -Be '127.0.0.1'
        $o['verification-method'] | Should -Be 'use-permanent-password'
        $o['approve-mode'] | Should -Be 'password'
        $o['enable-lan-discovery'] | Should -Be 'N'
    }
    It 'refuses a non-Tailscale address: <_>' -ForEach @('192.168.0.10', '100.64.0.0/10', '0.0.0.0') {
        { Get-HostOption -ControllerIp @($_) } | Should -Throw '*Not a Tailscale address*'
    }
}

Describe 'Select-ReleaseAsset' {
    BeforeAll {
        $hash = 'a' * 64
        $script:release = [pscustomobject]@{
            tag_name = '1.5.3'
            assets   = @(
                [pscustomobject]@{ name = 'rustdesk-1.5.3-x86_64.msi'; browser_download_url = 'https://example.invalid/msi'; digest = "sha256:$hash" }
                [pscustomobject]@{ name = 'rustdesk-1.5.3-x86-sciter.exe'; browser_download_url = 'https://example.invalid/32'; digest = "sha256:$hash" }
                [pscustomobject]@{ name = 'rustdesk-1.5.3-x86_64.exe'; browser_download_url = 'https://example.invalid/exe'; digest = "sha256:$($hash.ToUpper())" }
            )
        }
    }
    It 'picks the 64-bit .exe and its lowercase SHA-256' {
        $a = Select-ReleaseAsset -Release $script:release
        $a.Name | Should -Be 'rustdesk-1.5.3-x86_64.exe'
        $a.Url | Should -Be 'https://example.invalid/exe'
        $a.Sha256 | Should -Be ('a' * 64)
    }
    It 'refuses an asset without a published SHA-256' {
        $r = [pscustomobject]@{ tag_name = 'x'; assets = @([pscustomobject]@{ name = 'rustdesk-1.5.3-x86_64.exe'; browser_download_url = 'u' }) }
        { Select-ReleaseAsset -Release $r } | Should -Throw '*SHA-256*'
    }
    It 'refuses a digest that is not SHA-256' {
        $r = [pscustomobject]@{ tag_name = 'x'; assets = @([pscustomobject]@{ name = 'rustdesk-1.5.3-x86_64.exe'; browser_download_url = 'u'; digest = 'md5:abc' }) }
        { Select-ReleaseAsset -Release $r } | Should -Throw '*SHA-256*'
    }
    It 'refuses a release with no 64-bit Windows installer' {
        $r = [pscustomobject]@{ tag_name = 'x'; assets = @([pscustomobject]@{ name = 'rustdesk-1.5.3.dmg'; browser_download_url = 'u'; digest = "sha256:$('b' * 64)" }) }
        { Select-ReleaseAsset -Release $r } | Should -Throw '*64-bit*'
    }
}

Describe 'Get-FirewallFinding' {
    It 'passes when every rule is limited to Tailscale' {
        $rules = @(
            [pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Inbound'; InterfaceAlias = @('Tailscale') }
            [pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Outbound'; InterfaceAlias = 'Tailscale' }
        )
        $f = Get-FirewallFinding -Rule $rules
        @($f | Where-Object { -not $_.Pass }).Count | Should -Be 0
        $f.Count | Should -Be 3
    }
    It 'fails a rule on every adapter or on more than Tailscale' {
        $rules = @(
            [pscustomobject]@{ DisplayName = 'rustdesk.exe'; Direction = 'Inbound'; InterfaceAlias = @('Any') }
            [pscustomobject]@{ DisplayName = 'rustdesk.exe'; Direction = 'Inbound'; InterfaceAlias = @('Tailscale', 'Wi-Fi') }
        )
        @(Get-FirewallFinding -Rule $rules | Where-Object { -not $_.Pass }).Count | Should -Be 2
    }
    It 'fails when there are no rules' {
        (Get-FirewallFinding -Rule @())[0].Pass | Should -BeFalse
    }
}

Describe 'Get-WhitelistFinding' {
    It 'passes single Tailscale addresses' {
        @(Get-WhitelistFinding -Whitelist '100.64.0.10, 100.64.0.11' | Where-Object { -not $_.Pass }).Count | Should -Be 0
    }
    It 'fails an empty whitelist' {
        (Get-WhitelistFinding -Whitelist '')[0].Pass | Should -BeFalse
    }
    It 'fails a range, 0.0.0.0 or a home address: <_>' -ForEach @('100.64.0.0/10', '0.0.0.0', '192.168.0.10') {
        @(Get-WhitelistFinding -Whitelist "100.64.0.10,$_" | Where-Object { -not $_.Pass }).Count | Should -Be 1
    }
}

Describe 'Get-OptionFinding' {
    It 'passes matching values, ignoring surrounding spaces' {
        $f = Get-OptionFinding -Wanted ([ordered]@{ 'direct-server' = 'Y' }) -Actual @{ 'direct-server' = " Y`r`n" }
        $f.Pass | Should -BeTrue
    }
    It 'fails a missing or different value' {
        $f = Get-OptionFinding -Wanted ([ordered]@{ a = 'Y'; b = 'N' }) -Actual @{ a = 'N' }
        @($f | Where-Object { -not $_.Pass }).Count | Should -Be 2
    }
}

Describe 'Get-PortTestVerdict' {
    It 'passes when reachability matches what is wanted' {
        (Get-PortTestVerdict -Label 't' -Reachable $true -ShouldBeReachable $true).Pass | Should -BeTrue
        (Get-PortTestVerdict -Label 'h' -Reachable $false -ShouldBeReachable $false).Pass | Should -BeTrue
    }
    It 'fails an open port that should be closed' {
        (Get-PortTestVerdict -Label 'h' -Reachable $true -ShouldBeReachable $false).Pass | Should -BeFalse
    }
}

Describe 'Script files' {
    It 'are ASCII only, because Windows PowerShell 5.1 misreads other characters: <_>' -ForEach @(
        Get-ChildItem -Path (Join-Path $PSScriptRoot '../../scripts/windows') -File | ForEach-Object { $_.FullName }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes($_)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
