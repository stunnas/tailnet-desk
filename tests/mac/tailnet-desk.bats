#!/usr/bin/env bats
# Tests for scripts/mac/tailnet-desk.sh and the Mac scripts' argument checks. They change nothing on the system: only
# functions without system access are called, and the scripts are only run up to their input checks.
# Each call runs in /bin/bash with set -euo pipefail, as the scripts do: on a Mac that is bash 3.2, the version the
# scripts are written for. Run: bats tests/mac
# Every address below is a documented example or made up.

setup() {
  ROOT="$BATS_TEST_DIRNAME/../.."
  LIB="$ROOT/scripts/mac/tailnet-desk.sh"
}

# Runs a library function in /bin/bash with the scripts' error settings.
td() {
  run /bin/bash -c 'set -euo pipefail; . "$1"; shift; "$@"' td "$LIB" "$@"
}

# Runs a shell snippet in /bin/bash with the library loaded.
td_sh() {
  run /bin/bash -c 'set -euo pipefail; . "$1"; eval "$2"' td "$LIB" "$1"
}

@test "td_is_ipv4 accepts one address and refuses malformed ones" {
  for a in 192.168.0.10 0.0.0.0 100.64.0.10; do td td_is_ipv4 "$a"; [ "$status" -eq 0 ]; done
  for a in 256.1.1.1 192.168.0 myhost ' 192.168.0.10' 192.168.000.10 '' 192.168.0.10/24 $'192.168.0.10\n'; do # check-private-data: allow
    td td_is_ipv4 "$a"; [ "$status" -ne 0 ]
  done
}

@test "td_is_tailscale_ipv4 accepts only 100.64.0.0/10" {
  for a in 100.64.0.0 100.64.0.10 100.127.255.255; do td td_is_tailscale_ipv4 "$a"; [ "$status" -eq 0 ]; done
  for a in 100.63.255.255 100.128.0.0 192.168.0.10 100.64.0.0/10 0.0.0.0; do # check-private-data: allow
    td td_is_tailscale_ipv4 "$a"; [ "$status" -ne 0 ]
  done
}

@test "td_is_home_ipv4 accepts only private ranges" {
  for a in 192.168.0.10 10.0.0.1 172.16.0.1 172.31.255.254; do td td_is_home_ipv4 "$a"; [ "$status" -eq 0 ]; done # check-private-data: allow
  for a in 100.64.0.10 127.0.0.1 0.0.0.0 8.8.8.8 172.32.0.1 172.15.0.1 192.169.0.1 myhost; do # check-private-data: allow
    td td_is_home_ipv4 "$a"; [ "$status" -ne 0 ]
  done
}

@test "td_address_list splits commas, trims, drops blanks and repeats, keeping order" {
  td td_address_list ' 100.64.0.12, 100.64.0.11' '' '100.64.0.12,'
  [ "$status" -eq 0 ]
  [ "$output" = $'100.64.0.12\n100.64.0.11' ]
}

@test "td_resolve_controllers uses the given addresses over the whitelist" {
  td td_resolve_controllers 100.64.0.11 100.64.0.12
  [ "$output" = 100.64.0.11 ]
}

@test "td_resolve_controllers keeps valid whitelist entries, never this Mac's own" {
  td td_resolve_controllers '' '100.64.0.11, 0.0.0.0, 100.64.0.10' 100.64.0.10
  [ "$status" -eq 0 ]
  [ "$output" = 100.64.0.11 ]
}

@test "td_resolve_controllers refuses a non-Tailscale address and this Mac's own" {
  td td_resolve_controllers 192.168.0.10
  [ "$status" -eq 2 ]
  [[ "$output" == *"Not a Tailscale address"* ]]
  td td_resolve_controllers '100.64.0.11,100.64.0.10' '' 100.64.0.10
  [ "$status" -eq 2 ]
  [[ "$output" == *"this Mac's own address"* ]]
}

@test "td_host_options turns direct access on with exactly the controllers, and off without" {
  td td_host_options 100.64.0.11 100.64.0.12
  [[ "$output" == *$'whitelist=100.64.0.11,100.64.0.12\ndirect-server=Y'* ]]
  td td_host_options
  [[ "$output" == *'direct-server=N'* ]]
  [[ "$output" != *'whitelist='* ]]
}

@test "td_host_options always uses no public servers and the permanent password only" {
  td td_host_options
  for want in custom-rendezvous-server=127.0.0.1 relay-server=127.0.0.1 verification-method=use-permanent-password \
    approve-mode=password enable-lan-discovery=N; do
    [[ $'\n'"$output"$'\n' == *$'\n'"$want"$'\n'* ]]
  done
}

@test "td_host_option_keys lists the whitelist and every setting, once each" {
  td td_host_option_keys
  [ "$output" = "$(printf '%s\n' whitelist custom-rendezvous-server relay-server verification-method approve-mode enable-lan-discovery direct-server)" ]
}

@test "td_option_matches ignores spaces, treats empty direct-server as off, and compares whitelists as sets" {
  td td_option_matches relay-server 127.0.0.1 $' 127.0.0.1\r\n'; [ "$status" -eq 0 ]
  td td_option_matches direct-server N ''; [ "$status" -eq 0 ]
  td td_option_matches direct-server Y ''; [ "$status" -ne 0 ]
  td td_option_matches enable-lan-discovery N ''; [ "$status" -ne 0 ]
  td td_option_matches whitelist 100.64.0.11,100.64.0.12 '100.64.0.12, 100.64.0.11'; [ "$status" -eq 0 ]
  td td_option_matches whitelist 100.64.0.11 100.64.0.11,100.64.0.12; [ "$status" -ne 0 ]
}

@test "td_whitelist_change reports removed entries when controllers are kept" {
  td td_whitelist_change 100.64.0.11,0.0.0.0 100.64.0.11
  [ "$output" = $'removed\n0.0.0.0' ]
}

@test "td_whitelist_change reports entries left in place when nothing is kept, and nothing when all are kept" {
  td td_whitelist_change 100.64.0.0/10
  [ "$output" = $'kept\n100.64.0.0/10' ]
  td td_whitelist_change 100.64.0.11 100.64.0.11
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

good='custom-rendezvous-server=127.0.0.1
relay-server=127.0.0.1
verification-method=use-permanent-password
approve-mode=password
enable-lan-discovery=N'

@test "td_host_findings passes a host with direct access off and no controllers" {
  td_sh "printf '%s\nwhitelist=\ndirect-server=\n' '$good' | td_host_findings '' 100.64.0.10"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *PASS* ]]
}

@test "td_host_findings passes a whitelisted controller with direct access on" {
  td_sh "printf '%s\nwhitelist=100.64.0.11\ndirect-server=Y\n' '$good' | td_host_findings '' 100.64.0.10"
  [[ "$output" != *FAIL* ]]
}

@test "td_host_findings fails a range left in the whitelist while direct access is off" {
  td_sh "printf '%s\nwhitelist=100.64.0.0/10\ndirect-server=\n' '$good' | td_host_findings '' 100.64.0.10"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'FAIL\tWhitelist entry \'100.64.0.0/10\' is one Tailscale address'* ]]
}

@test "td_host_findings fails an empty whitelist while direct access is on" {
  td_sh "printf '%s\nwhitelist=\ndirect-server=Y\n' '$good' | td_host_findings '' 100.64.0.10"
  [[ "$output" == *$'FAIL\tWhitelist is not empty while direct IP access is on'* ]]
}

@test "td_host_findings fails this Mac's own address in the whitelist" {
  td_sh "printf '%s\nwhitelist=100.64.0.10\ndirect-server=\n' '$good' | td_host_findings '' 100.64.0.10"
  [[ "$output" == *$'FAIL\tWhitelist doesn\'t include this Mac\'s own address'* ]]
}

@test "td_host_findings reports an invalid given controller and a whitelist that differs from the given ones" {
  td_sh "printf '%s\nwhitelist=100.64.0.11\ndirect-server=Y\n' '$good' | td_host_findings '192.168.0.10' ''"
  [[ "$output" == *$'FAIL\tGiven controller address \'192.168.0.10\' is one Tailscale address'* ]]
  td_sh "printf '%s\nwhitelist=100.64.0.11\ndirect-server=Y\n' '$good' | td_host_findings '100.64.0.12' ''"
  [[ "$output" == *$'FAIL\tRustDesk setting whitelist'* ]]
}

@test "td_host_findings reports every failed setting, not just the first, under set -e" {
  td_sh "printf 'whitelist=\ndirect-server=\n' | td_host_findings '' ''"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^FAIL' <<< "$output")" -eq 5 ]
}

@test "td_print_findings returns 0 only when everything passed, and fails when nothing ran" {
  td_sh "printf 'PASS\ta\nPASS\tb\n' | td_print_findings"
  [ "$status" -eq 0 ]
  td_sh "printf 'PASS\ta\nFAIL\tb\tx\n' | td_print_findings"
  [ "$status" -ne 0 ]
  [[ "$output" == *'FAIL  b  (x)'* ]]
  td_sh "printf '' | td_print_findings"
  [ "$status" -ne 0 ]
  [[ "$output" == *'No checks ran'* ]]
}

@test "td_pf_rules lets Tailscale in on IPv4 and IPv6 before blocking the port everywhere else" {
  td td_pf_rules
  [ "$(sed -n 2p <<< "$output")" = 'pass in quick inet proto tcp from 100.64.0.0/10 to 100.64.0.0/10 port 21118' ]
  [ "$(sed -n 3p <<< "$output")" = 'pass in quick inet6 proto tcp from fd7a:115c:a1e0::/48 to fd7a:115c:a1e0::/48 port 21118' ] # check-private-data: allow
  [ "$(sed -n 4p <<< "$output")" = 'block drop in quick proto tcp from any to any port 21118' ]
}

@test "td_pf_loader takes its own pf reference, never stops pf, and is valid bash" {
  td td_pf_loader
  [[ "$output" == *'/sbin/pfctl -E'* ]]
  [[ "$output" == *"-a 'com.apple/tailnet-desk' -f"* ]]
  [[ "$output" != *'pfctl -d'* ]]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/load-pf.sh"
  /bin/bash -n "$BATS_TEST_TMPDIR/load-pf.sh"
}

@test "td_pf_plist is a valid property list that runs the loader at boot" {
  td td_pf_plist
  [[ "$output" == *'<key>RunAtLoad</key><true/>'* ]]
  [[ "$output" == *'load-pf.sh'* ]]
  if command -v plutil > /dev/null; then
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/p.plist"
    plutil -lint "$BATS_TEST_TMPDIR/p.plist"
  fi
}

@test "td_pf_token_from_output reads pfctl -E's token" {
  td_sh "printf 'No ALTQ support in kernel\nALTQ related functions disabled\npf enabled\nToken : 1234567\n' | td_pf_token_from_output"
  [ "$output" = 1234567 ]
  td_sh "printf 'pfctl: something else\n' | td_pf_token_from_output"
  [ -z "$output" ]
}

@test "td_team_from_codesign reads the signing team" {
  td_sh "printf 'Identifier=com.carriez.rustdesk\nTeamIdentifier=HZF9JMC8YN\n' | td_team_from_codesign"
  [ "$output" = HZF9JMC8YN ]
  td_sh "printf 'TeamIdentifier=not set\n' | td_team_from_codesign"
  [ "$output" = 'not set' ]
}

@test "td_rustdesk_asset names the right disk image and hash for each Mac type" {
  td td_rustdesk_asset arm64
  [ "$(sed -n 1p <<< "$output")" = rustdesk-1.5.3-aarch64.dmg ]
  [ "$(sed -n 2p <<< "$output" | wc -c | tr -d ' ')" -eq 65 ]
  td td_rustdesk_asset x86_64
  [ "$(sed -n 1p <<< "$output")" = rustdesk-1.5.3-x86_64.dmg ]
  td td_rustdesk_asset sparc
  [ "$status" -eq 2 ]
}

@test "the Mac and Windows scripts pin the same RustDesk version" {
  mac=$(sed -n "s/^TD_RUSTDESK_VERSION='\(.*\)'.*/\1/p" "$LIB")
  win=$(sed -n "s/^ *RustDeskVersion *= *'\([^']*\)'.*/\1/p" "$ROOT/scripts/windows/TailnetDesk.psm1")
  [ -n "$mac" ]
  [ "$mac" = "$win" ]
}

@test "test-from-controller.sh refuses bad addresses before testing anything" {
  run /bin/bash "$ROOT/scripts/mac/test-from-controller.sh" --host-tailscale-ip 192.168.0.10
  [ "$status" -eq 2 ]
  [[ "$output" == *'Not a Tailscale address'* ]]
  run /bin/bash "$ROOT/scripts/mac/test-from-controller.sh" --host-tailscale-ip 100.64.0.10 --host-home-ip 127.0.0.1
  [ "$status" -eq 2 ]
  [[ "$output" == *'Not a home network address'* ]]
}

@test "the scripts refuse unknown options and print their usage on --help" {
  for s in install-host test-host test-from-controller enable-pf undo-pf; do
    run /bin/bash "$ROOT/scripts/mac/$s.sh" --no-such-option
    [ "$status" -eq 2 ]
    run /bin/bash "$ROOT/scripts/mac/$s.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'Usage:'* ]]
  done
}

@test "install-host.sh refuses an invalid controller address before changing anything" {
  run /bin/bash "$ROOT/scripts/mac/install-host.sh" --controller-ip 100.64.0.0/10
  [ "$status" -eq 2 ]
  [[ "$output" == *'Not a Tailscale address'* ]]
  [[ "$output" != *'Step 1'* ]]
}
