# Pester 5 tests for scripts/windows/TailnetDesk.psm1. They change nothing on the system: the checks are pure, and the
# installer test mocks every system call. CI runs them in PowerShell 7 on Linux and Windows PowerShell 5.1 on Windows.
# Run locally: Invoke-Pester -Path tests/windows

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../scripts/windows/TailnetDesk.psm1') -Force
}

Describe 'Test-TailscaleIPv4' {
    It 'accepts addresses inside 100.64.0.0/10: <_>' -ForEach @('100.64.0.0', '100.64.0.10', '100.127.255.255') {
        Test-TailscaleIPv4 -Address $_ | Should -BeTrue
    }
    # Boundary and malformed values below are made up. check-private-data: allow
    It 'rejects <_>' -ForEach @('100.63.255.255', '100.128.0.0', '192.168.0.10', '100.64.0.256', '100.64.0', # check-private-data: allow
        '100.64.0.0/10', ' 100.64.0.10', '100.64.0.10 ', "100.64.0.10`n", '100.064.0.10', '', 'abc', '0.0.0.0') { # check-private-data: allow
        Test-TailscaleIPv4 -Address $_ | Should -BeFalse
    }
    It 'rejects non-ASCII digits, which .NET counts as digits' {
        Test-TailscaleIPv4 -Address "1$([char]0x0660)0.64.0.10" | Should -BeFalse # check-private-data: allow
    }
}

Describe 'ConvertTo-AddressList' {
    It 'splits commas, trims, drops blanks and repeats' {
        $r = ConvertTo-AddressList -Address @(' 100.64.0.10, 100.64.0.11', '', '100.64.0.10 ')
        ($r -join '|') | Should -Be '100.64.0.10|100.64.0.11'
    }
    It 'returns an empty list for nothing' {
        @(ConvertTo-AddressList -Address @()).Count | Should -Be 0
        @(ConvertTo-AddressList -Address $null).Count | Should -Be 0
    }
}

Describe 'Resolve-ControllerIp' {
    It 'uses the given addresses over the current whitelist' {
        (Resolve-ControllerIp -ControllerIp '100.64.0.11' -CurrentWhitelist '100.64.0.12') -join ',' | Should -Be '100.64.0.11'
    }
    It 'keeps the valid current whitelist entries when none are given' {
        (Resolve-ControllerIp -CurrentWhitelist '100.64.0.11, 0.0.0.0') -join ',' | Should -Be '100.64.0.11'
    }
    It 'returns nothing when nothing is given or whitelisted' {
        @(Resolve-ControllerIp).Count | Should -Be 0
    }
    It 'refuses a given non-Tailscale address: <_>' -ForEach @('192.168.0.10', '100.64.0.0/10', '0.0.0.0') {
        { Resolve-ControllerIp -ControllerIp @($_) } | Should -Throw '*Not a Tailscale address*'
    }
    It "refuses this PC's own address, alone or in a comma-separated list" {
        { Resolve-ControllerIp -ControllerIp '100.64.0.10' -OwnIp '100.64.0.10' } | Should -Throw "*this PC's own address*"
        { Resolve-ControllerIp -ControllerIp '100.64.0.11,100.64.0.10' -OwnIp '100.64.0.10' } | Should -Throw "*this PC's own address*"
    }
    It "accepts other addresses when this PC's own is known" {
        (Resolve-ControllerIp -ControllerIp '100.64.0.11' -OwnIp '100.64.0.10') -join ',' | Should -Be '100.64.0.11'
    }
    It "drops this PC's own address from the kept whitelist" {
        (Resolve-ControllerIp -CurrentWhitelist '100.64.0.10,100.64.0.11' -OwnIp '100.64.0.10') -join ',' | Should -Be '100.64.0.11'
    }
}

Describe 'Get-HostOption' {
    It 'turns on direct IP access and whitelists exactly the controllers' {
        $o = Get-HostOption -ControllerIp @('100.64.0.11', '100.64.0.12')
        $o['direct-server'] | Should -Be 'Y'
        $o['whitelist'] | Should -Be '100.64.0.11,100.64.0.12'
    }
    It 'turns direct IP access off without controllers, so an empty whitelist never opens the port' {
        $o = Get-HostOption
        $o['direct-server'] | Should -Be 'N'
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
}

Describe 'Test-OptionValue' {
    It 'matches equal values, ignoring spaces around them' {
        Test-OptionValue -Key 'relay-server' -Want '127.0.0.1' -Have " 127.0.0.1`r`n" | Should -BeTrue
    }
    It 'counts an empty direct-server as off, and only that key' {
        Test-OptionValue -Key 'direct-server' -Want 'N' -Have '' | Should -BeTrue
        Test-OptionValue -Key 'direct-server' -Want 'Y' -Have '' | Should -BeFalse
        Test-OptionValue -Key 'enable-lan-discovery' -Want 'N' -Have '' | Should -BeFalse
    }
    It 'compares whitelists as sets' {
        Test-OptionValue -Key 'whitelist' -Want '100.64.0.11,100.64.0.12' -Have '100.64.0.12, 100.64.0.11' | Should -BeTrue
        Test-OptionValue -Key 'whitelist' -Want '100.64.0.11' -Have '100.64.0.11,100.64.0.12' | Should -BeFalse
    }
}

Describe 'Get-HostSettingFinding' {
    BeforeAll {
        $script:good = @{
            'custom-rendezvous-server' = '127.0.0.1'; 'relay-server' = '127.0.0.1'; 'verification-method' = 'use-permanent-password'
            'approve-mode' = 'password'; 'enable-lan-discovery' = 'N'
        }
        function New-Current([hashtable]$Extra) { $h = $script:good.Clone(); foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }; $h }
    }
    It 'passes a host with direct access off and no controllers' {
        $f = Get-HostSettingFinding -Current (New-Current @{ 'direct-server' = ''; whitelist = '' })
        @($f | Where-Object { -not $_.Pass }).Count | Should -Be 0
    }
    It 'judges the current whitelist when no controllers are given' {
        $f = Get-HostSettingFinding -Current (New-Current @{ 'direct-server' = 'Y'; whitelist = '100.64.0.11' })
        @($f | Where-Object { -not $_.Pass }).Count | Should -Be 0
    }
    It 'fails direct access with an empty whitelist' {
        $f = Get-HostSettingFinding -Current (New-Current @{ 'direct-server' = 'Y'; whitelist = '' })
        @($f | Where-Object { -not $_.Pass }).Check | Should -Contain 'Whitelist is not empty while direct IP access is on'
    }
    It 'fails a range in the whitelist, naming the entry' {
        $f = Get-HostSettingFinding -Current (New-Current @{ 'direct-server' = 'Y'; whitelist = '100.64.0.11,100.64.0.0/10' })
        @($f | Where-Object { -not $_.Pass }).Check | Should -Contain "Whitelist entry '100.64.0.0/10' is one Tailscale address"
    }
    It 'reports an invalid given controller instead of ignoring it' {
        $f = Get-HostSettingFinding -ControllerIp '192.168.0.10' -Current (New-Current @{ 'direct-server' = ''; whitelist = '' })
        @($f | Where-Object { -not $_.Pass }).Check | Should -Contain "Given controller address '192.168.0.10' is one Tailscale address"
    }
    It 'fails when the whitelist differs from the given controllers' {
        $f = Get-HostSettingFinding -ControllerIp '100.64.0.12' -Current (New-Current @{ 'direct-server' = 'Y'; whitelist = '100.64.0.11' })
        @($f | Where-Object { -not $_.Pass }).Check | Should -Contain 'RustDesk setting whitelist'
    }
}

Describe 'Select-ReleaseAsset' {
    BeforeAll {
        $script:hash = 'a' * 64
        function New-Release([string]$Url, $Digest) {
            $asset = [pscustomobject]@{ name = 'rustdesk-1.5.3-x86_64.exe'; browser_download_url = $Url }
            if ($null -ne $Digest) { $asset | Add-Member -NotePropertyName digest -NotePropertyValue $Digest }
            [pscustomobject]@{ tag_name = '1.5.3'; assets = @(
                    [pscustomobject]@{ name = 'rustdesk-1.5.3-x86_64.msi'; browser_download_url = 'https://github.com/rustdesk/rustdesk/releases/download/1.5.3/x.msi' }
                    $asset) }
        }
        $script:okUrl = 'https://github.com/rustdesk/rustdesk/releases/download/1.5.3/rustdesk-1.5.3-x86_64.exe'
    }
    It 'returns the pinned asset when GitHub agrees with the pinned SHA-256' {
        $a = Select-ReleaseAsset -Release (New-Release $script:okUrl "sha256:$($script:hash.ToUpper())") -AssetName 'rustdesk-1.5.3-x86_64.exe' -Sha256 $script:hash
        $a.Url | Should -Be $script:okUrl
        $a.Sha256 | Should -Be $script:hash
    }
    It 'works when GitHub publishes no digest (the pinned hash is still checked after download)' {
        (Select-ReleaseAsset -Release (New-Release $script:okUrl $null) -AssetName 'rustdesk-1.5.3-x86_64.exe' -Sha256 $script:hash).Name |
            Should -Be 'rustdesk-1.5.3-x86_64.exe'
    }
    It 'refuses when GitHub publishes a different SHA-256' {
        { Select-ReleaseAsset -Release (New-Release $script:okUrl "sha256:$('b' * 64)") -AssetName 'rustdesk-1.5.3-x86_64.exe' -Sha256 $script:hash } |
            Should -Throw '*differs from the pinned*'
    }
    It 'refuses a download address outside github.com/rustdesk/rustdesk' {
        { Select-ReleaseAsset -Release (New-Release 'https://example.invalid/rustdesk-1.5.3-x86_64.exe' $null) -AssetName 'rustdesk-1.5.3-x86_64.exe' -Sha256 $script:hash } |
            Should -Throw "*isn't on github.com/rustdesk/rustdesk*"
    }
    It 'refuses a release without the pinned file' {
        { Select-ReleaseAsset -Release (New-Release $script:okUrl $null) -AssetName 'rustdesk-9.9.9-x86_64.exe' -Sha256 $script:hash } |
            Should -Throw '*no file named*'
    }
}

Describe 'Install-RustDesk' {
    It 'installs nothing and cleans up when the download does not match the pinned SHA-256' {
        Mock -ModuleName TailnetDesk Get-RustDeskExe { $null }
        Mock -ModuleName TailnetDesk Invoke-RestMethod {
            $s = Get-TailnetDeskSetting
            [pscustomobject]@{ tag_name = $s.RustDeskVersion; assets = @([pscustomobject]@{
                        name = $s.RustDeskAsset; browser_download_url = "https://github.com/rustdesk/rustdesk/releases/download/$($s.RustDeskVersion)/$($s.RustDeskAsset)" }) }
        }
        Mock -ModuleName TailnetDesk New-PrivateFolder { 'private-folder' }
        Mock -ModuleName TailnetDesk Invoke-WebRequest { }
        Mock -ModuleName TailnetDesk Open-LockedFile { New-Object IO.MemoryStream }
        Mock -ModuleName TailnetDesk Get-FileHash { [pscustomobject]@{ Hash = 'C' * 64 } }
        Mock -ModuleName TailnetDesk Start-Process { throw 'must not run' }
        Mock -ModuleName TailnetDesk Remove-Item { }

        { Install-RustDesk } | Should -Throw "*doesn't match the pinned one*"
        Should -Invoke -ModuleName TailnetDesk Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName TailnetDesk Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'private-folder' }
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

Describe 'Test-PortSpecCover' {
    It 'covers <_>' -ForEach @('Any', '21118', ' 21118 ', '21000-22000', '21118-21118') {
        Test-PortSpecCover -Spec $_ -Port 21118 | Should -BeTrue
    }
    It 'does not cover <_>' -ForEach @('21119', '80', '21119-22000', '1-21117', '', 'RPC') {
        Test-PortSpecCover -Spec $_ -Port 21118 | Should -BeFalse
    }
}

Describe 'Get-FirewallFinding options' {
    It 'leaves out the "rules exist" result and prefixes each check when asked' {
        $f = @(Get-FirewallFinding -Rule @([pscustomobject]@{ DisplayName = 'Open 21118'; Direction = 'Inbound'; InterfaceAlias = 'Any' }) -Prefix 'Port rule: ' -SkipCountCheck)
        $f.Count | Should -Be 1
        $f[0].Check | Should -BeLike 'Port rule: *'
        $f[0].Pass | Should -BeFalse
    }
    It 'returns nothing for no rules when the count check is skipped' {
        @(Get-FirewallFinding -Rule @() -SkipCountCheck).Count | Should -Be 0
    }
}

Describe 'Get-PortTestVerdict' {
    It 'passes when reachability matches what is wanted' {
        (Get-PortTestVerdict -Label 't' -Reachable $true -ShouldBeReachable $true).Pass | Should -BeTrue
        (Get-PortTestVerdict -Label 'h' -Reachable $false -ShouldBeReachable $false).Pass | Should -BeTrue
    }
    It 'fails an open port that should be closed, and a closed port that should be open' {
        (Get-PortTestVerdict -Label 'h' -Reachable $true -ShouldBeReachable $false).Pass | Should -BeFalse
        (Get-PortTestVerdict -Label 't' -Reachable $false -ShouldBeReachable $true).Pass | Should -BeFalse
    }
}

Describe 'Write-Finding' {
    BeforeAll { Mock -ModuleName TailnetDesk Write-Host { } }
    It 'returns true when all passed' {
        Write-Finding -Finding @([pscustomobject]@{ Check = 'a'; Pass = $true; Detail = '' }) | Should -BeTrue
    }
    It 'returns false when any failed' {
        Write-Finding -Finding @(
            [pscustomobject]@{ Check = 'a'; Pass = $true; Detail = '' }
            [pscustomobject]@{ Check = 'b'; Pass = $false; Detail = 'x' }) | Should -BeFalse
    }
    It 'returns false when there is nothing to report, so an empty check never passes' {
        Write-Finding -Finding @() | Should -BeFalse
    }
}

Describe 'Script files' {
    BeforeDiscovery {
        $script:files = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../../scripts/windows') -File | ForEach-Object { $_.FullName })
    }
    It 'include the module (so the ASCII test below never runs on nothing)' -ForEach @(@{ Files = $script:files }) {
        $Files.Count | Should -BeGreaterThan 0
        ($Files | Split-Path -Leaf) | Should -Contain 'TailnetDesk.psm1'
    }
    It 'are ASCII only, because Windows PowerShell 5.1 misreads other characters: <_>' -ForEach $script:files {
        $bytes = [System.IO.File]::ReadAllBytes($_)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
