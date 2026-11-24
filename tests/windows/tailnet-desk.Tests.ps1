# Pester 5 tests for scripts/windows/tailnet-desk.psm1. They change nothing on the system: the checks are pure, and the
# tests of system functions mock every system call. CI runs them in PowerShell 7 on Linux and Windows PowerShell 5.1
# on Windows. Run locally: Invoke-Pester -Path tests/windows

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../scripts/windows/tailnet-desk.psm1') -Force

    # Off Windows these commands don't exist, and Pester can only mock a command that does. The stubs are never run:
    # every test that reaches one mocks it. On Windows the real commands are mocked instead.
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        function global:Get-NetAdapter { [CmdletBinding()] param([string[]]$Name) throw 'stub' }
    }
    # The Set-NetFirewallRule mocks remove the types of InputObject and InterfaceAlias (Windows types them as
    # CimInstance and WildcardPattern), so the stubs leave parameters untyped too and both systems check the same thing.
    if (-not (Get-Command Set-NetFirewallRule -ErrorAction SilentlyContinue)) {
        function global:Set-NetFirewallRule {
            [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, $InterfaceAlias, $EdgeTraversalPolicy)
            process { throw 'stub' }
        }
    }
    if (-not (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallRule {
            [CmdletBinding()] param($DisplayName, $PolicyStore)
            throw 'stub'
        }
    }
    if (-not (Get-Command Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallApplicationFilter { [CmdletBinding()] param($PolicyStore) throw 'stub' }
    }
    if (-not (Get-Command Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallPortFilter { [CmdletBinding()] param($PolicyStore) throw 'stub' }
    }
    if (-not (Get-Command Get-Acl -ErrorAction SilentlyContinue)) {
        function global:Get-Acl { [CmdletBinding()] param([string]$LiteralPath) throw 'stub' }
    }
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        function global:Get-Service { [CmdletBinding()] param([string[]]$Name) throw 'stub' }
    }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        function global:Get-NetTCPConnection { [CmdletBinding()] param($LocalPort, $State) throw 'stub' }
    }

    # A stand-in for rustdesk.exe: prints a value for --option <key>, and exits 3 for the key 'broken'.
    $script:fakeExe = Join-Path $TestDrive 'fake-rustdesk.ps1'
    Set-Content -LiteralPath $script:fakeExe -Value @(
        'if ($args[1] -eq ''broken'') { exit 3 }'
        '"value-of-$($args[1])"'
        'exit 0'
    )
}

Describe 'Test-TailscaleIPv4' {
    It 'accepts addresses inside 100.64.0.0/10: <_>' -ForEach @('100.64.0.0', '100.64.0.10', '100.127.255.255') {
        Test-TailscaleIPv4 -Address $_ | Should -BeTrue
    }
    # Boundary and malformed values below are made up. check-private-data: allow
    It 'rejects <_>' -ForEach @('100.63.255.255', '100.128.0.0', '192.168.0.10', '100.64.0.256', '100.64.0', # check-private-data: allow
        '100.64.0.0/10', ' 100.64.0.10', '100.64.0.10 ', "100.64.0.10`n", '100.064.0.10', '', 'abc', '0.0.0.0', # check-private-data: allow
        'fd7a:115c:a1e0::1', '[fd7a:115c:a1e0::1]') { # Tailscale's own IPv6 form: the guides use 100.x only. check-private-data: allow
        Test-TailscaleIPv4 -Address $_ | Should -BeFalse
    }
    It 'rejects non-ASCII digits, which .NET counts as digits' {
        # In the last octet, so a \d pattern would let it through ([int] reads it as a digit), not drop it.
        Test-TailscaleIPv4 -Address "100.64.0.1$([char]0x0660)" -ErrorVariable e | Should -BeFalse # check-private-data: allow
        $e | Should -BeNullOrEmpty
    }
}

Describe 'Test-IPv4' {
    It 'accepts <_>' -ForEach @('192.168.0.10', '0.0.0.0', '100.64.0.10') {
        Test-IPv4 -Address $_ | Should -BeTrue
    }
    # Malformed values below are made up. check-private-data: allow
    It 'rejects <_>' -ForEach @('256.1.1.1', '192.168.0', 'myhost', ' 192.168.0.10', '192.168.000.10', '', '192.168.0.10/24') { # check-private-data: allow
        Test-IPv4 -Address $_ | Should -BeFalse
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
    It "drops a Tailscale IPv6 entry from the current whitelist, keeping the 100.x one" {
        (Resolve-ControllerIp -CurrentWhitelist '100.64.0.11, fd7a:115c:a1e0::1') -join ',' | Should -Be '100.64.0.11' # check-private-data: allow
    }
    It 'returns nothing when nothing is given or whitelisted' {
        @(Resolve-ControllerIp).Count | Should -Be 0
    }
    It 'refuses a given non-Tailscale address: <_>' -ForEach @('192.168.0.10', '100.64.0.0/10', '0.0.0.0', 'fd7a:115c:a1e0::1') { # check-private-data: allow
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

Describe 'Get-WhitelistChange' {
    It 'reports entries as removed when valid controllers are kept, because the whitelist is rewritten' {
        $c = Get-WhitelistChange -CurrentWhitelist '100.64.0.11,0.0.0.0' -Kept @('100.64.0.11')
        ($c.NotKept -join ',') | Should -Be '0.0.0.0'
        $c.Removed | Should -BeTrue
    }
    It 'reports entries as left in place when nothing is kept, because the whitelist is not rewritten' {
        $c = Get-WhitelistChange -CurrentWhitelist '100.64.0.0/10' -Kept @()
        ($c.NotKept -join ',') | Should -Be '100.64.0.0/10'
        $c.Removed | Should -BeFalse
    }
    It 'reports nothing when every entry is kept' {
        $c = Get-WhitelistChange -CurrentWhitelist '100.64.0.11' -Kept @('100.64.0.11')
        $c.NotKept.Count | Should -Be 0
        $c.Removed | Should -BeFalse
    }
    It 'matches what Get-HostOption writes: a rewritten whitelist only with kept controllers' {
        (Get-HostOption -ControllerIp @('100.64.0.11')).Contains('whitelist') | Should -BeTrue
        (Get-HostOption).Contains('whitelist') | Should -BeFalse
    }
}

Describe 'Get-HostOptionKey' {
    It 'lists the whitelist and every setting Get-HostOption sets, once each' {
        $keys = @(Get-HostOptionKey)
        $keys | Should -Contain 'whitelist'
        foreach ($k in (Get-HostOption -ControllerIp '100.64.0.11').Keys) { $keys | Should -Contain $k }
        @($keys | Select-Object -Unique).Count | Should -Be $keys.Count
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
    It "fails a whitelist that includes this PC's own address" {
        $f = Get-HostSettingFinding -OwnIp '100.64.0.10' -Current (New-Current @{ 'direct-server' = 'Y'; whitelist = '100.64.0.10,100.64.0.11' })
        @($f | Where-Object { -not $_.Pass }).Check | Should -Contain "Whitelist doesn't include this PC's own address"
    }
    It 'fails a range left in the whitelist while direct access is off, so turning it on later is caught' {
        $f = Get-HostSettingFinding -Current (New-Current @{ 'direct-server' = ''; whitelist = '100.64.0.0/10' })
        @($f | Where-Object { -not $_.Pass }).Check | Should -Contain "Whitelist entry '100.64.0.0/10' is one Tailscale address"
    }
    It "fails this PC's own address in the whitelist while direct access is off" {
        $f = Get-HostSettingFinding -OwnIp '100.64.0.10' -Current (New-Current @{ 'direct-server' = ''; whitelist = '100.64.0.10' })
        @($f | Where-Object { -not $_.Pass }).Check | Should -Contain "Whitelist doesn't include this PC's own address"
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

Describe 'Get-SubjectField' {
    It 'reads a plain field, a quoted field with a comma, and nothing for a missing field' {
        $subject = 'CN=PURSLANE, O="Example, Inc.", OID.2.5.4.15=Business Entity, C=SG'
        Get-SubjectField -Subject $subject -Field 'CN' | Should -Be 'PURSLANE'
        Get-SubjectField -Subject $subject -Field 'O' | Should -Be 'Example, Inc.'
        Get-SubjectField -Subject $subject -Field 'C' | Should -Be 'SG'
        Get-SubjectField -Subject $subject -Field 'L' | Should -BeNullOrEmpty
        Get-SubjectField -Subject '' -Field 'CN' | Should -BeNullOrEmpty
    }
    It 'never takes O from an OID field' {
        Get-SubjectField -Subject 'CN=X, OID.1.3.6.1.4.1.311.60.2.1.3=SG' -Field 'O' | Should -BeNullOrEmpty
    }
    It "never reads a field out of another field's quoted value" {
        Get-SubjectField -Subject 'CN=PURSLANE, OU="x, O=PURSLANE, y", O=Other' -Field 'O' | Should -Be 'Other'
    }
    It 'gives nothing for a field that appears twice, or a subject it cannot read' {
        Get-SubjectField -Subject 'CN=PURSLANE, O=PURSLANE, O=Other' -Field 'O' | Should -BeNullOrEmpty
        Get-SubjectField -Subject 'CN=PURSLANE, O="unclosed' -Field 'CN' | Should -BeNullOrEmpty
    }
    It 'turns doubled quotes inside a quoted value into one' {
        Get-SubjectField -Subject 'CN=X, O="A ""B"" C"' -Field 'O' | Should -Be 'A "B" C'
    }
}

Describe 'Test-PublisherSignature' {
    BeforeAll {
        function New-Signature([string]$Status, [string]$Subject) {
            [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }
        }
        # The signers of RustDesk's 1.5.3 installer and Tailscale's 1.104.4 installer, as Windows writes them.
        $script:rustdesk = 'CN=PURSLANE, O=PURSLANE, S=North West, C=SG, SERIALNUMBER=53481265A, OID.2.5.4.15=Business Entity, OID.1.3.6.1.4.1.311.60.2.1.3=SG'
        $script:tailscale = 'CN=Tailscale Inc., O=Tailscale Inc., L=Toronto, S=Ontario, C=CA, SERIALNUMBER=1131559-5, OID.2.5.4.15=Private Organization, OID.1.3.6.1.4.1.311.60.2.1.3=CA'
    }
    It 'accepts a valid signature from the pinned publishers' {
        $s = Get-TailnetDeskSetting
        Test-PublisherSignature -Signature (New-Signature 'Valid' $script:rustdesk) -Publisher $s.RustDeskSigner | Should -BeTrue
        Test-PublisherSignature -Signature (New-Signature 'Valid' $script:tailscale) -Publisher $s.TailscaleSigner | Should -BeTrue
    }
    It 'refuses a signature that is not valid: <_>' -ForEach @('NotSigned', 'HashMismatch', 'NotTrusted', 'UnknownError') {
        Test-PublisherSignature -Signature (New-Signature $_ $script:rustdesk) -Publisher 'PURSLANE' | Should -BeFalse
    }
    It 'refuses another publisher, a match in only CN or O, a different case, and no signature' {
        Test-PublisherSignature -Signature (New-Signature 'Valid' $script:tailscale) -Publisher 'PURSLANE' | Should -BeFalse
        Test-PublisherSignature -Signature (New-Signature 'Valid' 'CN=PURSLANE, O=Someone Else') -Publisher 'PURSLANE' | Should -BeFalse
        Test-PublisherSignature -Signature (New-Signature 'Valid' 'CN=Someone Else, O=PURSLANE') -Publisher 'PURSLANE' | Should -BeFalse
        Test-PublisherSignature -Signature (New-Signature 'Valid' 'CN=purslane, O=purslane') -Publisher 'PURSLANE' | Should -BeFalse
        Test-PublisherSignature -Signature $null -Publisher 'PURSLANE' | Should -BeFalse
        Test-PublisherSignature -Signature ([pscustomobject]@{ Status = 'Valid'; SignerCertificate = $null }) -Publisher 'PURSLANE' | Should -BeFalse
    }
    It "refuses the publisher's name hidden in another field, and a second O" {
        Test-PublisherSignature -Signature (New-Signature 'Valid' 'CN=PURSLANE, OU="x, O=PURSLANE, y", O=Other') -Publisher 'PURSLANE' | Should -BeFalse
        Test-PublisherSignature -Signature (New-Signature 'Valid' 'CN=PURSLANE, O=PURSLANE, O=Other') -Publisher 'PURSLANE' | Should -BeFalse
    }
}

Describe 'Get-SignatureFinding' {
    It 'passes a validly signed program, and fails a bad signature or one that cannot be read' {
        Mock -ModuleName tailnet-desk Get-FileSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=PURSLANE, O=PURSLANE' } }
        }
        $f = Get-SignatureFinding -Name 'RustDesk' -Path 'rustdesk.exe' -Publisher 'PURSLANE' -Detail 'reinstall'
        $f.Check | Should -Be 'RustDesk is signed by its publisher (PURSLANE)'
        $f.Pass | Should -BeTrue
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq 'rustdesk.exe' }
        Mock -ModuleName tailnet-desk Get-FileSignature { [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = $null } }
        (Get-SignatureFinding -Name 'RustDesk' -Path 'rustdesk.exe' -Publisher 'PURSLANE' -Detail 'x').Pass | Should -BeFalse
        Mock -ModuleName tailnet-desk Get-FileSignature { throw 'in use' }
        $f = Get-SignatureFinding -Name 'RustDesk' -Path 'rustdesk.exe' -Publisher 'PURSLANE' -Detail 'x'
        $f.Pass | Should -BeFalse
        $f.Detail | Should -BeLike "*couldn't read its signature (in use)*"
    }
}

Describe 'Windows guides' {
    It 'both tell you to check RustDesk for the publisher the script checks: <_>' -ForEach @('host-windows', 'controller-windows') {
        $guide = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "../../docs/$_.md")
        $guide | Should -BeLike "*Digital Signatures*must show **$((Get-TailnetDeskSetting).RustDeskSigner)***"
    }
}

Describe 'Install-RustDesk' {
    BeforeEach {
        Mock -ModuleName tailnet-desk Get-FileSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=PURSLANE, O=PURSLANE, C=SG' } }
        }
        # Not installed at the first look; installed once the (mocked) installer has run.
        $script:installed = $false
        Mock -ModuleName tailnet-desk Get-RustDeskExe { if ($script:installed) { 'rustdesk.exe' } else { $null } }
        Mock -ModuleName tailnet-desk Invoke-RestMethod {
            $s = Get-TailnetDeskSetting
            [pscustomobject]@{ tag_name = $s.RustDeskVersion; assets = @([pscustomobject]@{
                        name = $s.RustDeskAsset; browser_download_url = "https://github.com/$($s.RustDeskRepo)/releases/download/$($s.RustDeskVersion)/$($s.RustDeskAsset)" }) }
        }
        Mock -ModuleName tailnet-desk New-PrivateFolder { 'private-folder' }
        Mock -ModuleName tailnet-desk Invoke-WebRequest { }
        Mock -ModuleName tailnet-desk Open-LockedFile { New-Object IO.MemoryStream }
        Mock -ModuleName tailnet-desk Get-FileHash { [pscustomobject]@{ Hash = (Get-TailnetDeskSetting).RustDeskSha256.ToUpperInvariant() } }
        $script:exitCode = 0
        Mock -ModuleName tailnet-desk Start-Process {
            $script:installed = ($script:exitCode -eq 0)
            [pscustomobject]@{ ExitCode = $script:exitCode } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
        }
        Mock -ModuleName tailnet-desk Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock -ModuleName tailnet-desk Start-Sleep { }
        Mock -ModuleName tailnet-desk Remove-Item { }
        Mock -ModuleName tailnet-desk Write-Host { }
    }
    It 'installs nothing and cleans up when the download does not match the pinned SHA-256' {
        Mock -ModuleName tailnet-desk Get-FileHash { [pscustomobject]@{ Hash = 'C' * 64 } }
        { Install-RustDesk } | Should -Throw "*doesn't match the pinned one*"
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Open-LockedFile -Times 1 -Exactly
        Should -Invoke -ModuleName tailnet-desk Get-FileHash -Times 1 -Exactly -ParameterFilter { $null -ne $InputStream }
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'private-folder' }
    }
    It 'installs nothing and cleans up when the download is not validly signed by RustDesk' {
        Mock -ModuleName tailnet-desk Get-FileSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { Install-RustDesk } | Should -Throw "*isn't validly signed by its publisher (PURSLANE)*"
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'private-folder' }
    }
    It 'runs the silent install when the hash matches, then deletes the download folder' {
        Install-RustDesk
        $download = Join-Path 'private-folder' (Get-TailnetDeskSetting).RustDeskAsset
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq $download }
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq 'rustdesk.exe' }
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 1 -Exactly -ParameterFilter { "$ArgumentList" -eq '--silent-install' }
        Should -Invoke -ModuleName tailnet-desk Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'private-folder' }
    }
    It "throws when the installer fails, and still deletes the download folder" {
        $script:exitCode = 5
        { Install-RustDesk } | Should -Throw '*installer failed (exit code 5)*'
        Should -Invoke -ModuleName tailnet-desk Remove-Item -Times 1 -Exactly
    }
    It "throws when the service doesn't start within a minute" {
        Mock -ModuleName tailnet-desk Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        # Each look at the clock is 10 seconds later, so the minute runs out without waiting.
        $script:clock = [datetime]'2026-01-01'
        Mock -ModuleName tailnet-desk Get-Date { $script:clock = $script:clock.AddSeconds(10); $script:clock }
        { Install-RustDesk } | Should -Throw "*service didn't start within a minute*"
    }
    It 'creates no folder and downloads nothing when the release is refused' {
        Mock -ModuleName tailnet-desk Invoke-RestMethod { [pscustomobject]@{ tag_name = 'x'; assets = @() } }
        { Install-RustDesk } | Should -Throw '*no file named*'
        Should -Invoke -ModuleName tailnet-desk New-PrivateFolder -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Invoke-WebRequest -Times 0 -Exactly
    }
    It 'downloads and installs nothing when no folder was made (-WhatIf)' {
        Mock -ModuleName tailnet-desk New-PrivateFolder { $null }
        Install-RustDesk
        Should -Invoke -ModuleName tailnet-desk Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 0 -Exactly
    }
    It 'keeps an installed RustDesk that passes the signature check' {
        $script:installed = $true
        Install-RustDesk
        Should -Invoke -ModuleName tailnet-desk Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq 'rustdesk.exe' }
    }
    It "refuses an installed RustDesk that isn't validly signed, and downloads nothing" {
        $script:installed = $true
        Mock -ModuleName tailnet-desk Get-FileSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { Install-RustDesk } | Should -Throw "*rustdesk.exe in Program Files isn't validly signed*"
        Should -Invoke -ModuleName tailnet-desk Invoke-RestMethod -Times 0 -Exactly
    }
    It 'warns instead of failing when the download folder cannot be deleted' {
        Mock -ModuleName tailnet-desk Remove-Item { throw 'in use' }
        Mock -ModuleName tailnet-desk Write-Warning { }
        Install-RustDesk
        Should -Invoke -ModuleName tailnet-desk Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*private-folder*' }
    }
}

Describe 'Test-RustDeskListening' {
    BeforeEach {
        # A clock that moves 2 seconds per sleep, so the waiting is tested without real time passing.
        $script:now = [datetime]'2026-01-01'
        Mock -ModuleName tailnet-desk Get-Date { $script:now }
        Mock -ModuleName tailnet-desk Start-Sleep { $script:now = $script:now.AddSeconds(2) }
        Mock -ModuleName tailnet-desk Write-Host { }
    }
    It 'passes at once when the port is already listening' {
        Mock -ModuleName tailnet-desk Get-NetTCPConnection { [pscustomobject]@{ LocalPort = 21118 } }
        Test-RustDeskListening -Port 21118 | Should -BeTrue
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Get-NetTCPConnection -Times 1 -Exactly -ParameterFilter { $LocalPort -eq 21118 -and $State -eq 'Listen' }
    }
    It 'waits for RustDesk to open the port' {
        $script:looks = 0
        Mock -ModuleName tailnet-desk Get-NetTCPConnection { $script:looks++; if ($script:looks -ge 3) { [pscustomobject]@{ LocalPort = 21118 } } }
        Test-RustDeskListening -Port 21118 | Should -BeTrue
        $script:looks | Should -Be 3
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 1 -Exactly -ParameterFilter {
            "$Object" -eq '  Waiting up to 30 seconds for RustDesk to listen on TCP 21118 ...'
        }
    }
    It 'fails once the time is up' {
        Mock -ModuleName tailnet-desk Get-NetTCPConnection { }
        Test-RustDeskListening -Port 21118 -TimeoutSeconds 10 | Should -BeFalse
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 5 -Exactly
    }
    It 'waits the setting''s 30 seconds by default' {
        (Get-TailnetDeskSetting).ListenWaitSeconds | Should -Be 30
        Mock -ModuleName tailnet-desk Get-NetTCPConnection { }
        Test-RustDeskListening -Port 21118 | Should -BeFalse
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 15 -Exactly
    }
    It 'looks once and says nothing with no time to wait' {
        Mock -ModuleName tailnet-desk Get-NetTCPConnection { }
        Test-RustDeskListening -Port 21118 -TimeoutSeconds 0 | Should -BeFalse
        Should -Invoke -ModuleName tailnet-desk Get-NetTCPConnection -Times 1 -Exactly
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 0 -Exactly
    }
    # The mocks write their errors with -ErrorAction Continue, as the real command does when called with
    # SilentlyContinue: a mock body otherwise follows the caller's preference, which is Stop in CI.
    It 'takes "not found" for a closed port, but throws any other error at once' {
        Mock -ModuleName tailnet-desk Get-NetTCPConnection {
            Write-Error -Message 'No matching objects found' -Category ObjectNotFound -ErrorAction Continue
        }
        Test-RustDeskListening -Port 21118 -TimeoutSeconds 2 | Should -BeFalse
        Mock -ModuleName tailnet-desk Get-NetTCPConnection {
            Write-Error -Message 'Access denied' -Category PermissionDenied -ErrorAction Continue
        }
        { Test-RustDeskListening -Port 21118 } | Should -Throw '*Access denied*'
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 1 -Exactly
    }
    # The check relies on Windows reporting "nothing listening" as ObjectNotFound; this asks the real command.
    It 'gets "not found" from the real Get-NetTCPConnection for a closed port' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $closed = 1..200 | ForEach-Object { 40000 + $_ } |
            Where-Object { -not (Get-NetTCPConnection -LocalPort $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
        $closed | Should -Not -BeNullOrEmpty
        $null = Get-NetTCPConnection -LocalPort $closed -State Listen -ErrorAction SilentlyContinue -ErrorVariable lookupError
        @($lookupError).Count | Should -BeGreaterThan 0
        { Assert-OnlyNotFound -ErrorRecord $lookupError } | Should -Not -Throw
    }
}

Describe 'Get-ListeningFinding' {
    It 'passes when RustDesk listens, and the check names the port' {
        Mock -ModuleName tailnet-desk Test-RustDeskListening { $true }
        $f = Get-ListeningFinding
        $f.Check | Should -Be 'RustDesk listens on TCP 21118'
        $f.Pass | Should -BeTrue
        Should -Invoke -ModuleName tailnet-desk Test-RustDeskListening -Times 1 -Exactly -ParameterFilter { $Port -eq 21118 -and $TimeoutSeconds -eq 30 }
    }
    It 'fails with how long it waited' {
        Mock -ModuleName tailnet-desk Test-RustDeskListening { $false }
        $f = Get-ListeningFinding -TimeoutSeconds 12
        $f.Pass | Should -BeFalse
        $f.Detail | Should -Be 'nothing listening after 12 seconds'
    }
    It 'fails with the error when the ports cannot be read' {
        Mock -ModuleName tailnet-desk Test-RustDeskListening { throw 'Access denied' }
        $f = Get-ListeningFinding
        $f.Pass | Should -BeFalse
        $f.Detail | Should -BeLike "couldn't read the listening ports (*Access denied*)"
    }
}

Describe 'Wait-TailscaleIPv4' {
    BeforeEach {
        # A clock that moves 3 seconds per sleep, so the waiting is tested without real time passing.
        $script:now = [datetime]'2026-01-01'
        Mock -ModuleName tailnet-desk Get-Date { $script:now }
        Mock -ModuleName tailnet-desk Start-Sleep { $script:now = $script:now.AddSeconds(3) }
        Mock -ModuleName tailnet-desk Write-Host { }
    }
    It 'gives the address at once, and says nothing, when Tailscale is signed in' {
        Mock -ModuleName tailnet-desk Get-TailscaleIPv4 { '100.64.0.10' }
        Wait-TailscaleIPv4 | Should -Be '100.64.0.10'
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 0 -Exactly
    }
    It 'says once how to sign in, then waits for the sign-in' {
        $script:looks = 0
        Mock -ModuleName tailnet-desk Get-TailscaleIPv4 { $script:looks++; if ($script:looks -ge 4) { '100.64.0.10' } }
        Wait-TailscaleIPv4 | Should -Be '100.64.0.10'
        $script:looks | Should -Be 4
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 1 -Exactly -ParameterFilter {
            "$Object" -eq "Waiting up to 10 minutes for the sign-in. The script goes on by itself once you're signed in."
        }
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like '*choose Log in*' }
    }
    It 'gives nothing once the time is up' {
        Mock -ModuleName tailnet-desk Get-TailscaleIPv4 { $null }
        Wait-TailscaleIPv4 -TimeoutSeconds 30 | Should -BeNullOrEmpty
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 10 -Exactly
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Waiting up to 1 minute for*' }
    }
    It 'waits the setting''s 10 minutes by default' {
        (Get-TailnetDeskSetting).SignInWaitSeconds | Should -Be 600
        Mock -ModuleName tailnet-desk Get-TailscaleIPv4 { $null }
        Wait-TailscaleIPv4 | Should -BeNullOrEmpty
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 200 -Exactly
    }
    It 'looks once and says nothing with no time to wait' {
        Mock -ModuleName tailnet-desk Get-TailscaleIPv4 { $null }
        Wait-TailscaleIPv4 -TimeoutSeconds 0 | Should -BeNullOrEmpty
        Should -Invoke -ModuleName tailnet-desk Get-TailscaleIPv4 -Times 1 -Exactly
        Should -Invoke -ModuleName tailnet-desk Start-Sleep -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 0 -Exactly
    }
}

Describe 'Read-ControllerIp' {
    BeforeEach {
        # Read-Host gives the next answer from $script:answers each time it's asked.
        $script:asked = 0
        Mock -ModuleName tailnet-desk Read-Host { $script:answers[$script:asked++] }
        Mock -ModuleName tailnet-desk Write-Host { }
    }
    It 'gives the typed address' {
        $script:answers = @(' 100.64.0.11 ')
        @(Read-ControllerIp -OwnIp '100.64.0.10') | Should -Be @('100.64.0.11')
        $script:asked | Should -Be 1
        Should -Invoke -ModuleName tailnet-desk Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -like '*press Enter to skip for now' }
    }
    It 'gives several comma-separated addresses, without repeats' {
        $script:answers = @('100.64.0.11, 100.64.0.12,100.64.0.11')
        @(Read-ControllerIp -OwnIp '100.64.0.10') | Should -Be @('100.64.0.11', '100.64.0.12')
    }
    It 'gives nothing when Enter is pressed' {
        $script:answers = @('')
        @(Read-ControllerIp -OwnIp '100.64.0.10').Count | Should -Be 0
    }
    It 'asks again after an address that is not a single Tailscale address, and says why' {
        $script:answers = @('192.168.0.10', '100.64.0.0/10', '100.64.0.11')
        @(Read-ControllerIp -OwnIp '100.64.0.10') | Should -Be @('100.64.0.11')
        $script:asked | Should -Be 3
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 1 -Exactly -ParameterFilter {
            "$Object" -like "*Not a Tailscale address: '192.168.0.10'*Type it again, or press Enter to skip."
        }
    }
    It 'asks again after this PC''s own address' {
        $script:answers = @('100.64.0.10', '')
        @(Read-ControllerIp -OwnIp '100.64.0.10').Count | Should -Be 0
        $script:asked | Should -Be 2
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like "*'100.64.0.10' is this PC's own address*" }
    }
    It 'names the controllers already whitelisted, and Enter keeps them' {
        $script:answers = @('')
        @(Read-ControllerIp -OwnIp '100.64.0.10' -Kept @('100.64.0.11')).Count | Should -Be 0
        Should -Invoke -ModuleName tailnet-desk Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -eq 'Controllers already on the whitelist: 100.64.0.11' }
        Should -Invoke -ModuleName tailnet-desk Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Press Enter to keep them*' }
    }
    It 'treats an ended input like Enter' {
        $script:answers = @()
        @(Read-ControllerIp -OwnIp '100.64.0.10').Count | Should -Be 0
    }
}

Describe 'New-PrivateFolder' {
    It 'refuses a folder that is a junction or link, before reading its owner or changing permissions' {
        Mock -ModuleName tailnet-desk Get-ProgramDataPath { $TestDrive }
        Mock -ModuleName tailnet-desk Test-Path { $true }
        Mock -ModuleName tailnet-desk Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]'Directory, ReparsePoint' } }
        { New-PrivateFolder } | Should -Throw '*is a link to another folder*'
        Should -Invoke -ModuleName tailnet-desk Get-Item -Times 1 -Exactly
    }
}

Describe 'Get-TailscaleIPv4' {
    BeforeAll {
        # A stand-in for tailscale.exe that prints whatever $env:FAKE_TAILSCALE_OUT holds.
        $script:fakeTailscale = Join-Path $TestDrive 'fake-tailscale.ps1'
        Set-Content -LiteralPath $script:fakeTailscale -Value '$env:FAKE_TAILSCALE_OUT'
    }
    BeforeEach {
        Mock -ModuleName tailnet-desk Get-FileSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Tailscale Inc., O=Tailscale Inc.' } }
        }
    }
    AfterEach { Remove-Item Env:\FAKE_TAILSCALE_OUT -ErrorAction SilentlyContinue }
    It 'never runs a tailscale.exe without Tailscale''s valid signature' {
        # The stand-in would print an address if it ran; a check that runs it anyway would return one.
        Mock -ModuleName tailnet-desk Get-TailscaleExe { $script:fakeTailscale }
        $env:FAKE_TAILSCALE_OUT = '100.64.0.10'
        Mock -ModuleName tailnet-desk Get-FileSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        Get-TailscaleIPv4 | Should -BeNullOrEmpty
        Mock -ModuleName tailnet-desk Get-FileSignature { throw 'in use' }
        Get-TailscaleIPv4 | Should -BeNullOrEmpty
    }
    It 'returns the address Tailscale prints' {
        Mock -ModuleName tailnet-desk Get-TailscaleExe { $script:fakeTailscale }
        $env:FAKE_TAILSCALE_OUT = "100.64.0.10`r`n"
        Get-TailscaleIPv4 | Should -Be '100.64.0.10'
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq $script:fakeTailscale }
    }
    It 'returns nothing for no output, extra lines, or Tailscale not installed' {
        Mock -ModuleName tailnet-desk Get-TailscaleExe { $script:fakeTailscale }
        $env:FAKE_TAILSCALE_OUT = ''
        Get-TailscaleIPv4 | Should -BeNullOrEmpty
        $env:FAKE_TAILSCALE_OUT = "100.64.0.10`nLogged out."
        Get-TailscaleIPv4 | Should -BeNullOrEmpty
        Mock -ModuleName tailnet-desk Get-TailscaleExe { $null }
        Get-TailscaleIPv4 | Should -BeNullOrEmpty
    }
}

Describe 'Get-RustDeskOption' {
    It "returns each setting RustDesk prints" {
        $v = Get-RustDeskOption -Exe $script:fakeExe -Key @('whitelist', 'relay-server')
        $v['whitelist'] | Should -Be 'value-of-whitelist'
        $v['relay-server'] | Should -Be 'value-of-relay-server'
    }
    It 'throws when RustDesk fails to read a setting, instead of treating it as empty' {
        { Get-RustDeskOption -Exe $script:fakeExe -Key @('broken') } | Should -Throw "*couldn't read the setting broken (exit code 3)*"
    }
}

Describe 'Set-RustDeskOption' {
    It "throws when RustDesk doesn't take a setting" {
        Mock -ModuleName tailnet-desk Get-RustDeskOption { @{ 'relay-server' = 'rs-ny.rustdesk.com' } }
        { Set-RustDeskOption -Exe $script:fakeExe -Option ([ordered]@{ 'relay-server' = '127.0.0.1' }) } |
            Should -Throw "*didn't take the setting relay-server*"
    }
    It 'passes when every setting reads back as written' {
        Mock -ModuleName tailnet-desk Get-RustDeskOption { @{ 'relay-server' = '127.0.0.1' } }
        { Set-RustDeskOption -Exe $script:fakeExe -Option ([ordered]@{ 'relay-server' = '127.0.0.1' }) } | Should -Not -Throw
    }
    It 'changes and reads nothing with -WhatIf' {
        Mock -ModuleName tailnet-desk Get-RustDeskOption { throw 'must not run' }
        Set-RustDeskOption -Exe $script:fakeExe -Option ([ordered]@{ 'relay-server' = '127.0.0.1' }) -WhatIf
        Should -Invoke -ModuleName tailnet-desk Get-RustDeskOption -Times 0 -Exactly
    }
}

Describe 'Firewall rule selection' {
    It 'keeps enabled Allow rules, in the named direction only' {
        Test-AllowRule -Rule ([pscustomobject]@{ Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound' }) -Direction Inbound | Should -BeTrue
        Test-AllowRule -Rule ([pscustomobject]@{ Action = 'Allow'; Enabled = 'True'; Direction = 'Outbound' }) | Should -BeTrue
        Test-AllowRule -Rule ([pscustomobject]@{ Action = 'Allow'; Enabled = 'True'; Direction = 'Outbound' }) -Direction Inbound | Should -BeFalse
    }
    It 'drops disabled rules and Block rules' {
        Test-AllowRule -Rule ([pscustomobject]@{ Action = 'Allow'; Enabled = 'False'; Direction = 'Inbound' }) | Should -BeFalse
        Test-AllowRule -Rule ([pscustomobject]@{ Action = 'Block'; Enabled = 'True'; Direction = 'Inbound' }) | Should -BeFalse
    }
    It 'matches port filters that let TCP in on the direct port: <Name>' -ForEach @(
        @{ Name = 'TCP range'; Protocol = 'TCP'; LocalPort = @('21000-22000') }
        @{ Name = 'any protocol, any port'; Protocol = 'Any'; LocalPort = @('Any') }
        @{ Name = 'one of several ports'; Protocol = 'TCP'; LocalPort = @('80', '21118') }
    ) {
        Test-PortFilterMatch -Filter ([pscustomobject]@{ Protocol = $Protocol; LocalPort = $LocalPort }) -Port 21118 | Should -BeTrue
    }
    It 'leaves out port filters that do not: <Name>' -ForEach @(
        @{ Name = 'UDP only'; Protocol = 'UDP'; LocalPort = @('21118') }
        @{ Name = 'another TCP port'; Protocol = 'TCP'; LocalPort = @('80') }
        @{ Name = 'ICMP'; Protocol = 'ICMPv4'; LocalPort = @('Any') }
    ) {
        Test-PortFilterMatch -Filter ([pscustomobject]@{ Protocol = $Protocol; LocalPort = $LocalPort }) -Port 21118 | Should -BeFalse
    }
}

Describe 'Assert-OnlyNotFound' {
    BeforeAll {
        function New-TestError([Management.Automation.ErrorCategory]$Category) {
            New-Object Management.Automation.ErrorRecord ([Exception]'test'), 'TestError', $Category, $null
        }
    }
    It 'lets "not found" errors and no errors through' {
        { Assert-OnlyNotFound -ErrorRecord @(New-TestError ObjectNotFound) } | Should -Not -Throw
        { Assert-OnlyNotFound -ErrorRecord @() } | Should -Not -Throw
        { Assert-OnlyNotFound -ErrorRecord $null } | Should -Not -Throw
    }
    It 'throws any other error, such as access denied' {
        { Assert-OnlyNotFound -ErrorRecord @((New-TestError ObjectNotFound), (New-TestError PermissionDenied)) } | Should -Throw
    }
}

Describe 'Set-RustDeskFirewallToTailscale' {
    BeforeEach {
        Mock -ModuleName tailnet-desk Get-NetAdapter { [pscustomobject]@{ Name = 'Tailscale' } }
        Mock -ModuleName tailnet-desk Set-NetFirewallRule { } -RemoveParameterType InputObject, InterfaceAlias
    }
    It 'throws when there is no Tailscale adapter, and changes nothing' {
        Mock -ModuleName tailnet-desk Get-NetAdapter { }
        { Set-RustDeskFirewallToTailscale } | Should -Throw "*No network adapter named 'Tailscale'*"
        Should -Invoke -ModuleName tailnet-desk Set-NetFirewallRule -Times 0 -Exactly
    }
    It 'throws when RustDesk has no firewall rules' {
        Mock -ModuleName tailnet-desk Get-RustDeskFirewallRule { @() }
        { Set-RustDeskFirewallToTailscale } | Should -Throw '*No RustDesk firewall rules found*'
    }
    It 'changes nothing with -WhatIf' {
        Mock -ModuleName tailnet-desk Get-RustDeskFirewallRule { @([pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Inbound'; EdgeTraversalPolicy = 'DeferToUser' }) }
        Set-RustDeskFirewallToTailscale -WhatIf
        Should -Invoke -ModuleName tailnet-desk Set-NetFirewallRule -Times 0 -Exactly
    }
    It 'switches a DeferToUser rule to Block and limits every rule to Tailscale' {
        Mock -ModuleName tailnet-desk Get-RustDeskFirewallRule { @(
                [pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Inbound'; EdgeTraversalPolicy = 'DeferToUser' }
                [pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Outbound'; EdgeTraversalPolicy = 'Block' }) }
        Set-RustDeskFirewallToTailscale
        Should -Invoke -ModuleName tailnet-desk Set-NetFirewallRule -Times 1 -Exactly -ParameterFilter { "$EdgeTraversalPolicy" -eq 'Block' }
        Should -Invoke -ModuleName tailnet-desk Set-NetFirewallRule -Times 2 -Exactly -ParameterFilter { @($InterfaceAlias) -contains 'Tailscale' }
    }
}

Describe 'Set-RustDeskFirewallToAny' {
    BeforeEach { Mock -ModuleName tailnet-desk Set-NetFirewallRule { } -RemoveParameterType InputObject, InterfaceAlias }
    It 'throws when there are no rules, so the undo never reports a change it did not make' {
        Mock -ModuleName tailnet-desk Get-RustDeskFirewallRule { @() }
        { Set-RustDeskFirewallToAny } | Should -Throw '*nothing to undo*'
    }
    It 'changes nothing with -WhatIf' {
        Mock -ModuleName tailnet-desk Get-RustDeskFirewallRule { @([pscustomobject]@{ DisplayName = 'rustdesk.exe'; Direction = 'Inbound' }) }
        Set-RustDeskFirewallToAny -WhatIf
        Should -Invoke -ModuleName tailnet-desk Set-NetFirewallRule -Times 0 -Exactly
    }
    It 'puts every rule back on every adapter' {
        Mock -ModuleName tailnet-desk Get-RustDeskFirewallRule { @([pscustomobject]@{ DisplayName = 'rustdesk.exe'; Direction = 'Inbound' }) }
        Set-RustDeskFirewallToAny
        Should -Invoke -ModuleName tailnet-desk Set-NetFirewallRule -Times 1 -Exactly -ParameterFilter { @($InterfaceAlias) -contains 'Any' }
    }
}

Describe 'Get-FirewallProfileFinding' {
    It 'passes a profile that is on and blocks by default' {
        $f = @(Get-FirewallProfileFinding -FirewallProfile @([pscustomobject]@{ Name = 'Public'; Enabled = 'True'; DefaultInboundAction = 'Block' }))
        $f.Count | Should -Be 2
        @($f | Where-Object { -not $_.Pass }).Count | Should -Be 0
    }
    It 'fails <Name>' -ForEach @(
        @{ Name = 'a profile that is off'; Enabled = 'False'; Action = 'Block' }
        @{ Name = 'Allow as the default'; Enabled = 'True'; Action = 'Allow' }
        @{ Name = 'NotConfigured as the default'; Enabled = 'True'; Action = 'NotConfigured' }
    ) {
        $f = @(Get-FirewallProfileFinding -FirewallProfile @([pscustomobject]@{ Name = 'Private'; Enabled = $Enabled; DefaultInboundAction = $Action }))
        @($f | Where-Object { -not $_.Pass }).Count | Should -Be 1
    }
    It 'fails when no profiles were read' {
        @(Get-FirewallProfileFinding -FirewallProfile @())[0].Pass | Should -BeFalse
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
    It 'names the protocol, so a TCP and a UDP rule with one name get different lines' {
        $rules = @(
            [pscustomobject]@{ DisplayName = 'rustdesk.exe'; Direction = 'Inbound'; Protocol = 'TCP'; InterfaceAlias = 'Tailscale' }
            [pscustomobject]@{ DisplayName = 'rustdesk.exe'; Direction = 'Inbound'; Protocol = 'UDP'; InterfaceAlias = 'Tailscale' }
        )
        $checks = @(Get-FirewallFinding -Rule $rules -SkipCountCheck).Check
        $checks[0] | Should -Be "Rule 'rustdesk.exe' (Inbound, TCP) only on Tailscale"
        $checks[1] | Should -Be "Rule 'rustdesk.exe' (Inbound, UDP) only on Tailscale"
    }
    It 'leaves out a protocol of Any or none' {
        $rules = @(
            [pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Inbound'; Protocol = 'Any'; InterfaceAlias = 'Tailscale' }
            [pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Outbound'; InterfaceAlias = 'Tailscale' }
        )
        $checks = @(Get-FirewallFinding -Rule $rules -SkipCountCheck).Check
        $checks[0] | Should -Be "Rule 'RustDesk Service' (Inbound) only on Tailscale"
        $checks[1] | Should -Be "Rule 'RustDesk Service' (Outbound) only on Tailscale"
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

Describe 'Expand-SystemDrivePath' {
    It 'fills in the drive from SystemRoot, in any letter case' {
        Expand-SystemDrivePath -Value '%SystemDrive%\ProgramData' -SystemRoot 'D:\WINDOWS' | Should -Be 'D:\ProgramData'
        Expand-SystemDrivePath -Value '%systemdrive%\ProgramData' -SystemRoot 'C:\Windows' | Should -Be 'C:\ProgramData'
    }
    It 'keeps a path that has no variable' {
        Expand-SystemDrivePath -Value 'C:\ProgramData' -SystemRoot 'C:\WINDOWS' | Should -Be 'C:\ProgramData'
    }
    It 'refuses any other variable, which would come from the environment' {
        { Expand-SystemDrivePath -Value '%USERPROFILE%\ProgramData' -SystemRoot 'C:\WINDOWS' } | Should -Throw "*Can't read the ProgramData folder*"
    }
    It 'refuses an empty value or a SystemRoot without a drive' {
        { Expand-SystemDrivePath -Value '' -SystemRoot 'C:\WINDOWS' } | Should -Throw
        { Expand-SystemDrivePath -Value '%SystemDrive%\ProgramData' -SystemRoot '%SystemDrive%\WINDOWS' } | Should -Throw "*system drive*"
    }
}

Describe 'Write-Finding' {
    BeforeAll { Mock -ModuleName tailnet-desk Write-Host { } }
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

Describe 'Test-ApplicationFilter' {
    It 'recognises RustDesk''s program, in any folder' {
        Test-ApplicationFilter -Filter ([pscustomobject]@{ Program = 'C:\Program Files\RustDesk\rustdesk.exe' }) -Program RustDesk | Should -BeTrue
        Test-ApplicationFilter -Filter ([pscustomobject]@{ Program = 'C:\Tools\browser.exe' }) -Program RustDesk | Should -BeFalse
    }
    It 'counts only Any as a rule for every program, so rules for one named program are left out' {
        Test-ApplicationFilter -Filter ([pscustomobject]@{ Program = 'Any' }) -Program Any | Should -BeTrue
        Test-ApplicationFilter -Filter ([pscustomobject]@{ Program = 'C:\Tools\game.exe' }) -Program Any | Should -BeFalse
        Test-ApplicationFilter -Filter $null -Program Any | Should -BeFalse
    }
}

Describe 'Test-HomeIPv4' {
    # Range ends and public examples below are made up. check-private-data: allow
    It 'accepts a private home address: <_>' -ForEach @('192.168.0.10', '10.0.0.1', '172.16.0.1', '172.31.255.254') { # check-private-data: allow
        Test-HomeIPv4 -Address $_ | Should -BeTrue
    }
    It 'refuses anything that would not test the home network: <_>' -ForEach @(
        '100.64.0.10', '127.0.0.1', '0.0.0.0', '8.8.8.8', '172.32.0.1', '172.15.0.1', '192.169.0.1', 'myhost', '192.168.0') { # check-private-data: allow
        Test-HomeIPv4 -Address $_ | Should -BeFalse
    }
}

Describe 'Get-RustDeskFirewallRule' {
    # The mocks write their errors with -ErrorAction Continue, so they stay non-terminating as a real cmdlet's do under
    # -ErrorAction SilentlyContinue, even when the caller's preference is Stop (as in GitHub Actions' pwsh steps).
    BeforeEach {
        Mock -ModuleName tailnet-desk Get-NetFirewallApplicationFilter { }
    }
    It 'treats a rule name that does not exist as no rule' {
        Mock -ModuleName tailnet-desk Get-NetFirewallRule { Write-Error -Message 'No rule' -Category ObjectNotFound -ErrorAction Continue }
        @(Get-RustDeskFirewallRule).Count | Should -Be 0
    }
    It 'stops on any other lookup error, such as access denied' {
        Mock -ModuleName tailnet-desk Get-NetFirewallRule { Write-Error -Message 'Access denied' -Category PermissionDenied -ErrorAction Continue }
        { Get-RustDeskFirewallRule } | Should -Throw '*Access denied*'
    }
    It "finds RustDesk's rules under another name through their program, and only RustDesk's" {
        Mock -ModuleName tailnet-desk Get-NetFirewallRule { Write-Error -Message 'No rule' -Category ObjectNotFound -ErrorAction Continue }
        Mock -ModuleName tailnet-desk Get-NetFirewallApplicationFilter { @(
                [pscustomobject]@{ Program = 'C:\Program Files\RustDesk\rustdesk.exe'; Rule = 'renamed' }
                [pscustomobject]@{ Program = 'C:\Tools\browser.exe'; Rule = 'browser' }) }
        Mock -ModuleName tailnet-desk Get-RuleOfFilter { [pscustomobject]@{ Name = $Filter.Rule; Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound' } }
        (@(Get-RustDeskFirewallRule).Name -join ',') | Should -Be 'renamed'
        Should -Invoke -ModuleName tailnet-desk Get-RuleOfFilter -Times 1 -Exactly
    }
    It 'reads the given policy store, such as ActiveStore, for both the name and the program lookups' {
        Mock -ModuleName tailnet-desk Get-NetFirewallRule { }
        $null = Get-RustDeskFirewallRule -PolicyStore ActiveStore
        $n = @((Get-TailnetDeskSetting).RuleNames).Count
        Should -Invoke -ModuleName tailnet-desk Get-NetFirewallRule -Times $n -Exactly -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
        Should -Invoke -ModuleName tailnet-desk Get-NetFirewallApplicationFilter -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
    }
    It 'reads the local store when no policy store is given' {
        Mock -ModuleName tailnet-desk Get-NetFirewallRule { }
        $null = Get-RustDeskFirewallRule
        Should -Invoke -ModuleName tailnet-desk Get-NetFirewallRule -Times 0 -ParameterFilter { $PolicyStore }
        Should -Invoke -ModuleName tailnet-desk Get-NetFirewallApplicationFilter -Times 0 -ParameterFilter { $PolicyStore }
    }
    It 'keeps enabled Allow rules once each, and drops Block rules' {
        Mock -ModuleName tailnet-desk Get-NetFirewallRule { @(
                [pscustomobject]@{ Name = 'a'; Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound' }
                [pscustomobject]@{ Name = 'b'; Action = 'Block'; Enabled = 'True'; Direction = 'Inbound' }) }
        $r = @(Get-RustDeskFirewallRule)
        ($r.Name -join ',') | Should -Be 'a'
    }
}

Describe 'Get-ProgramFilesPath and Get-ProgramDataPath' {
    It 'prefers the 64-bit Program Files folder, so 32-bit PowerShell finds the right one' {
        Mock -ModuleName tailnet-desk Get-ItemProperty { [pscustomobject]@{ ProgramFilesDir = 'C:\Program Files (x86)'; ProgramW6432Dir = 'C:\Program Files' } }
        Get-ProgramFilesPath | Should -Be 'C:\Program Files'
    }
    It 'falls back to ProgramFilesDir when there is no 64-bit value' {
        Mock -ModuleName tailnet-desk Get-ItemProperty { [pscustomobject]@{ ProgramFilesDir = 'C:\Program Files' } }
        Get-ProgramFilesPath | Should -Be 'C:\Program Files'
    }
    It 'reads ProgramData unexpanded and fills in the drive from SystemRoot' {
        # Answers like the registry: unexpanded only when asked for it, otherwise already filled in from the environment.
        Mock -ModuleName tailnet-desk Get-Item {
            [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
                param($n, $d, $o)
                if ($n -eq 'ProgramData' -and $o -eq [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) { '%SystemDrive%\ProgramData' }
                else { 'E:\FromEnvironment\ProgramData' }
            } -PassThru
        }
        Mock -ModuleName tailnet-desk Get-ItemProperty { [pscustomobject]@{ SystemRoot = 'D:\WINDOWS' } }
        Get-ProgramDataPath | Should -Be 'D:\ProgramData'
    }
    It 'refuses a SystemRoot without a drive, so no path is looked up from the current folder: "<_>"' -ForEach @('', 'WINDOWS', '%SystemDrive%\WINDOWS') {
        $script:root = $_
        Mock -ModuleName tailnet-desk Get-ItemProperty { [pscustomobject]@{ SystemRoot = $script:root } }
        { Get-System32Exe -Name 'icacls.exe' } | Should -Throw '*system drive*'
    }
    It 'finds Windows'' own programs in System32 under SystemRoot, never through PATH' {
        Mock -ModuleName tailnet-desk Get-ItemProperty { [pscustomobject]@{ SystemRoot = 'D:\WINDOWS' } }
        ((Get-System32Exe -Name 'icacls.exe') -replace '/', '\') | Should -Be 'D:\WINDOWS\System32\icacls.exe'
    }
}

Describe 'New-PrivateFolder failure paths' {
    BeforeEach {
        Mock -ModuleName tailnet-desk Get-ProgramDataPath { $TestDrive }
        Mock -ModuleName tailnet-desk New-Item { }
        Mock -ModuleName tailnet-desk Invoke-IcaclsTool { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName tailnet-desk Get-ChildItem { }
    }
    It 'refuses an existing folder that is not owned by Administrators or SYSTEM' {
        Mock -ModuleName tailnet-desk Test-Path { $true }
        Mock -ModuleName tailnet-desk Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::Directory } }
        Mock -ModuleName tailnet-desk Get-Acl {
            [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($t) [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } } -PassThru
        }
        { New-PrivateFolder } | Should -Throw "*isn't owned by Administrators*"
        Should -Invoke -ModuleName tailnet-desk Invoke-IcaclsTool -Times 0 -Exactly
    }
    It 'stops when icacls fails to restrict the permissions' {
        Mock -ModuleName tailnet-desk Test-Path { $false }
        Mock -ModuleName tailnet-desk Invoke-IcaclsTool { [pscustomobject]@{ ExitCode = 5; Output = 'Access is denied.' } }
        { New-PrivateFolder } | Should -Throw "*Couldn't restrict the permissions*exit code 5*Access is denied.*"
    }
    It 'stops when the new folder already holds something' {
        Mock -ModuleName tailnet-desk Test-Path { $false }
        Mock -ModuleName tailnet-desk Get-ChildItem { [pscustomobject]@{ Name = 'planted.exe' } }
        { New-PrivateFolder } | Should -Throw "*wasn't empty*"
    }
    It 'returns a new admin-only folder under ProgramData\tailnet-desk' {
        Mock -ModuleName tailnet-desk Test-Path { $false }
        $path = New-PrivateFolder
        $path | Should -BeLike (Join-Path (Join-Path $TestDrive 'tailnet-desk') '*')
        $want = '/inheritance:r|/grant:r|*S-1-5-32-544:(OI)(CI)F|*S-1-5-18:(OI)(CI)F'
        Should -Invoke -ModuleName tailnet-desk Invoke-IcaclsTool -Times 2 -Exactly -ParameterFilter { $a = @($Argument); ($a[1..($a.Count - 1)] -join '|') -eq $want }
        # Once on the shared folder and once on the new one.
        $root = Join-Path $TestDrive 'tailnet-desk'
        Should -Invoke -ModuleName tailnet-desk Invoke-IcaclsTool -Times 1 -Exactly -ParameterFilter { @($Argument)[0] -eq $root }
        Should -Invoke -ModuleName tailnet-desk Invoke-IcaclsTool -Times 1 -Exactly -ParameterFilter { @($Argument)[0] -eq $path }
    }
    It 'accepts an existing folder owned by <Name>, as on a second run' -ForEach @(
        @{ Name = 'Administrators'; Sid = 'S-1-5-32-544' }
        @{ Name = 'SYSTEM'; Sid = 'S-1-5-18' }
    ) {
        $script:ownerSid = $Sid
        # Only the shared tailnet-desk folder exists; the new random folder inside it doesn't yet.
        Mock -ModuleName tailnet-desk Test-Path { $LiteralPath -notmatch '[0-9a-f]{32}$' }
        Mock -ModuleName tailnet-desk Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::Directory } }
        Mock -ModuleName tailnet-desk Get-Acl {
            [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($t) [pscustomobject]@{ Value = $script:ownerSid } } -PassThru
        }
        New-PrivateFolder | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName tailnet-desk New-Item -Times 1 -Exactly
    }
    It 'makes nothing with -WhatIf' {
        New-PrivateFolder -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName tailnet-desk New-Item -Times 0 -Exactly
    }
}

Describe 'Get-PortAllowRule' {
    BeforeEach {
        # Each port filter names the rule it belongs to; each rule says its action, direction and program.
        Mock -ModuleName tailnet-desk Get-NetFirewallPortFilter { @(
                [pscustomobject]@{ Protocol = 'TCP'; LocalPort = @('21118'); Rule = 'open-any' }
                [pscustomobject]@{ Protocol = 'TCP'; LocalPort = @('21000-22000'); Rule = 'open-any' }
                [pscustomobject]@{ Protocol = 'TCP'; LocalPort = @('21118'); Rule = 'one-program' }
                [pscustomobject]@{ Protocol = 'Any'; LocalPort = @('Any'); Rule = 'blocked' }
                [pscustomobject]@{ Protocol = 'TCP'; LocalPort = @('21118'); Rule = 'outbound' }
                [pscustomobject]@{ Protocol = 'UDP'; LocalPort = @('21118'); Rule = 'udp' }) }
        $script:rules = @{
            'open-any'    = [pscustomobject]@{ Name = 'open-any'; Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound'; Program = 'Any' }
            'one-program' = [pscustomobject]@{ Name = 'one-program'; Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound'; Program = 'C:\Tools\game.exe' }
            'blocked'     = [pscustomobject]@{ Name = 'blocked'; Action = 'Block'; Enabled = 'True'; Direction = 'Inbound'; Program = 'Any' }
            'outbound'    = [pscustomobject]@{ Name = 'outbound'; Action = 'Allow'; Enabled = 'True'; Direction = 'Outbound'; Program = 'Any' }
            'udp'         = [pscustomobject]@{ Name = 'udp'; Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound'; Program = 'Any' }
        }
        Mock -ModuleName tailnet-desk Get-RuleOfFilter { $script:rules[$Filter.Rule] }
        Mock -ModuleName tailnet-desk Get-ApplicationFilterOfRule { [pscustomobject]@{ Program = $Rule.Program; Package = '' } }
        Mock -ModuleName tailnet-desk Get-AddressFilterOfRule { [pscustomobject]@{ LocalAddress = @('Any'); RemoteAddress = @('Any') } }
    }
    It 'leaves out Tailscale''s own rule (only this PC''s Tailscale addresses) and Windows app rules (with an owner)' {
        Mock -ModuleName tailnet-desk Get-NetFirewallPortFilter { @(
                [pscustomobject]@{ Protocol = 'Any'; LocalPort = @('Any'); Rule = 'open-any' }
                [pscustomobject]@{ Protocol = 'Any'; LocalPort = @('Any'); Rule = 'Tailscale-In' }
                [pscustomobject]@{ Protocol = 'Any'; LocalPort = @('Any'); Rule = 'Xbox' }) }
        $script:rules['Tailscale-In'] = [pscustomobject]@{ Name = 'Tailscale-In'; Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound'; Program = 'Any' }
        $script:rules['Xbox'] = [pscustomobject]@{ Name = 'Xbox'; Action = 'Allow'; Enabled = 'True'; Direction = 'Inbound'; Program = 'Any'; Owner = 'S-1-5-21-1-2-3-1001' }
        Mock -ModuleName tailnet-desk Get-AddressFilterOfRule {
            if ($Rule.Name -eq 'Tailscale-In') { [pscustomobject]@{ LocalAddress = @('100.64.0.10'); RemoteAddress = @('Any') } }
            else { [pscustomobject]@{ LocalAddress = @('Any'); RemoteAddress = @('Any') } }
        }
        (@(Get-PortAllowRule).Name -join ',') | Should -Be 'open-any'
    }
    It 'returns only enabled inbound Allow rules for any program that cover the port, once each' {
        (@(Get-PortAllowRule).Name -join ',') | Should -Be 'open-any'
    }
    It 'reads the given policy store, such as ActiveStore, and the local store without one' {
        $null = Get-PortAllowRule -PolicyStore ActiveStore
        Should -Invoke -ModuleName tailnet-desk Get-NetFirewallPortFilter -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
        $null = Get-PortAllowRule
        Should -Invoke -ModuleName tailnet-desk Get-NetFirewallPortFilter -Times 1 -Exactly -ParameterFilter { -not $PolicyStore }
    }
    It 'never looks up the rule of a filter that does not cover the port' {
        $null = Get-PortAllowRule
        Should -Invoke -ModuleName tailnet-desk Get-RuleOfFilter -Times 0 -ParameterFilter { $Filter.Rule -eq 'udp' }
    }
}

Describe 'Test-TailscaleAddressSpec' {
    # Addresses below are examples or made up. check-private-data: allow
    It 'accepts <_>' -ForEach @('100.64.0.10', '100.64.0.0/10', 'fd7a:115c:a1e0::1', 'fd7a:115c:a1e0::/48', 'FD7A:115C:A1E0:AB12::/64') { # check-private-data: allow
        Test-TailscaleAddressSpec -Spec $_ | Should -BeTrue
    }
    It 'refuses <_>' -ForEach @('Any', '', '192.168.0.10', '100.64.0.0/9', 'fd7a:115c:a1e1::1', 'fd7a:115c:a1e0::/32', 'LocalSubnet') { # check-private-data: allow
        Test-TailscaleAddressSpec -Spec $_ | Should -BeFalse
    }
}

Describe 'Test-OpenToAnyProgram' {
    BeforeAll {
        $script:anyApp = [pscustomobject]@{ Program = 'Any'; Package = '' }
        $script:anyAddr = [pscustomobject]@{ LocalAddress = @('Any'); RemoteAddress = @('Any') }
    }
    It 'flags a rule open to any program on any address' {
        Test-OpenToAnyProgram -Rule ([pscustomobject]@{ Owner = '' }) -ApplicationFilter $script:anyApp -AddressFilter $script:anyAddr | Should -BeTrue
    }
    It 'leaves out a rule with an owner, as Windows'' packaged apps have' {
        Test-OpenToAnyProgram -Rule ([pscustomobject]@{ Owner = 'S-1-5-21-1-2-3-1001' }) -ApplicationFilter $script:anyApp -AddressFilter $script:anyAddr | Should -BeFalse
    }
    It 'leaves out a rule for one program or one app package' {
        Test-OpenToAnyProgram -Rule ([pscustomobject]@{ Owner = '' }) -ApplicationFilter ([pscustomobject]@{ Program = 'C:\Tools\game.exe'; Package = '' }) -AddressFilter $script:anyAddr | Should -BeFalse
        Test-OpenToAnyProgram -Rule ([pscustomobject]@{ Owner = '' }) -ApplicationFilter ([pscustomobject]@{ Program = 'Any'; Package = 'S-1-15-2-1' }) -AddressFilter $script:anyAddr | Should -BeFalse
    }
    It 'leaves out a rule limited to this PC''s Tailscale addresses, like Tailscale-In' {
        $ts = [pscustomobject]@{ LocalAddress = @('100.64.0.10', 'fd7a:115c:a1e0::1'); RemoteAddress = @('Any') } # check-private-data: allow
        Test-OpenToAnyProgram -Rule ([pscustomobject]@{ Owner = '' }) -ApplicationFilter $script:anyApp -AddressFilter $ts | Should -BeFalse
    }
    It 'flags a rule whose local addresses include anything besides Tailscale' {
        $mixed = [pscustomobject]@{ LocalAddress = @('100.64.0.10', '192.168.0.10'); RemoteAddress = @('Any') }
        Test-OpenToAnyProgram -Rule ([pscustomobject]@{ Owner = '' }) -ApplicationFilter $script:anyApp -AddressFilter $mixed | Should -BeTrue
    }
}

Describe 'Get-FirewallRuleState' {
    It 'reads each rule''s name, direction, adapters and protocol' {
        Mock -ModuleName tailnet-desk Get-InterfaceAliasOfRule { @('Tailscale') }
        Mock -ModuleName tailnet-desk Get-ProtocolOfRule { 'UDP' }
        $s = @(Get-FirewallRuleState -Rule @([pscustomobject]@{ DisplayName = 'RustDesk Service'; Direction = 'Inbound' }))
        $s[0].DisplayName | Should -Be 'RustDesk Service'
        $s[0].Direction | Should -Be 'Inbound'
        ($s[0].InterfaceAlias -join ',') | Should -Be 'Tailscale'
        $s[0].Protocol | Should -Be 'UDP'
    }
}

Describe 'Install-Tailscale' {
    BeforeEach {
        # Not installed at the first look; installed once the (mocked) msiexec has run.
        $script:tsInstalled = $false
        Mock -ModuleName tailnet-desk Get-TailscaleExe { if ($script:tsInstalled) { 'tailscale.exe' } else { $null } }
        Mock -ModuleName tailnet-desk New-PrivateFolder { 'private-folder' }
        Mock -ModuleName tailnet-desk Invoke-WebRequest { }
        Mock -ModuleName tailnet-desk Open-LockedFile { New-Object IO.MemoryStream }
        Mock -ModuleName tailnet-desk Get-FileHash { [pscustomobject]@{ Hash = (Get-TailnetDeskSetting).TailscaleMsiSha256.ToUpperInvariant() } }
        Mock -ModuleName tailnet-desk Get-FileSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Tailscale Inc., O=Tailscale Inc., C=CA' } }
        }
        Mock -ModuleName tailnet-desk Get-System32Exe { "C:\Windows\System32\$Name" }
        $script:exitCode = 0
        Mock -ModuleName tailnet-desk Start-Process {
            $script:tsInstalled = ($script:exitCode -in 0, 3010)
            [pscustomobject]@{ ExitCode = $script:exitCode } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
        }
        Mock -ModuleName tailnet-desk Remove-Item { }
        Mock -ModuleName tailnet-desk Write-Host { }
    }
    It "downloads the pinned MSI from Tailscale's server, checks it, and installs it quietly with msiexec" {
        Install-Tailscale
        $s = Get-TailnetDeskSetting
        Should -Invoke -ModuleName tailnet-desk Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq "https://pkgs.tailscale.com/stable/tailscale-setup-$($s.TailscaleVersion)-amd64.msi" }
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path 'private-folder' $s.TailscaleMsi) }
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Windows\System32\msiexec.exe' -and ($ArgumentList -join ' ') -like '/i "*' + $s.TailscaleMsi + '" /quiet /norestart'
        }
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq 'tailscale.exe' }
        Should -Invoke -ModuleName tailnet-desk Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'private-folder' }
    }
    It 'installs nothing when the download does not match the pinned SHA-256' {
        Mock -ModuleName tailnet-desk Get-FileHash { [pscustomobject]@{ Hash = 'C' * 64 } }
        { Install-Tailscale } | Should -Throw "*doesn't match the pinned one*"
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'private-folder' }
    }
    It 'installs nothing when the download is not validly signed by Tailscale' {
        Mock -ModuleName tailnet-desk Get-FileSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Someone Else, O=Someone Else' } }
        }
        { Install-Tailscale } | Should -Throw "*isn't validly signed by its publisher (Tailscale Inc.)*"
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 0 -Exactly
    }
    It 'accepts exit code 3010 (installed, restart wanted) and throws on any other failure' {
        $script:exitCode = 3010
        Install-Tailscale
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq 'tailscale.exe' }
        Should -Invoke -ModuleName tailnet-desk Write-Host -ParameterFilter { "$Object" -like '*restart*' }
        $script:tsInstalled = $false
        $script:exitCode = 1603
        { Install-Tailscale } | Should -Throw "*Tailscale's installer failed (exit code 1603)*"
    }
    It "throws when the installer succeeds but tailscale.exe isn't there" {
        Mock -ModuleName tailnet-desk Start-Process {
            [pscustomobject]@{ ExitCode = 0 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
        }
        { Install-Tailscale } | Should -Throw "*tailscale.exe isn't in Program Files*"
    }
    It 'throws when the installed tailscale.exe is not validly signed' {
        Mock -ModuleName tailnet-desk Get-FileSignature -ParameterFilter { $Path -eq 'tailscale.exe' } {
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        }
        { Install-Tailscale } | Should -Throw "*installed tailscale.exe isn't validly signed by Tailscale (Tailscale Inc.)*"
    }
    It 'keeps an installed Tailscale that passes the signature check' {
        $script:tsInstalled = $true
        Install-Tailscale
        Should -Invoke -ModuleName tailnet-desk Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName tailnet-desk Get-FileSignature -Times 1 -Exactly -ParameterFilter { $Path -eq 'tailscale.exe' }
    }
    It "refuses an installed Tailscale that isn't validly signed" {
        $script:tsInstalled = $true
        Mock -ModuleName tailnet-desk Get-FileSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { Install-Tailscale } | Should -Throw "*tailscale.exe in Program Files isn't validly signed*"
        Should -Invoke -ModuleName tailnet-desk Invoke-WebRequest -Times 0 -Exactly
    }
    It 'installs nothing with -WhatIf' {
        Install-Tailscale -WhatIf
        Should -Invoke -ModuleName tailnet-desk Start-Process -Times 0 -Exactly
    }
}

Describe 'Script files' {
    BeforeDiscovery {
        # Every PowerShell file git tracks: Windows PowerShell 5.1 reads the scripts, the tools and these tests.
        # A recursive folder walk could follow a link out of the repo in Windows PowerShell 5.1; git's list doesn't.
        $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        # Mode 120000 is a symbolic link: skipped, so reading the files never follows a link out of the repo.
        $script:files = @(git -C $root ls-files -s -- '*.ps1' '*.psm1' '*.psd1' | Where-Object { $_ -notmatch '^120000 ' } |
                ForEach-Object { Join-Path $root ($_ -split "`t", 2)[1] })
    }
    It 'include the module (so the ASCII test below never runs on nothing)' -ForEach @(@{ Files = $script:files }) {
        $Files.Count | Should -BeGreaterThan 0
        ($Files | Split-Path -Leaf) | Should -Contain 'tailnet-desk.psm1'
    }
    It 'are ASCII only, because Windows PowerShell 5.1 misreads other characters: <_>' -ForEach $script:files {
        $bytes = [System.IO.File]::ReadAllBytes($_)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
