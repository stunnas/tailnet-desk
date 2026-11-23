#!/usr/bin/env bats
# Tests for scripts/mac/tailnet-desk.sh and the Mac scripts' argument checks. They change nothing on the system: the
# functions that touch it (the installers, and RustDesk's settings reads and writes) run only with stand-ins for the
# programs they call by fixed path, and the scripts are only run up to their input checks.
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
  for a in 100.63.255.255 100.128.0.0 192.168.0.10 100.64.0.0/10 0.0.0.0 fd7a:115c:a1e0::1 '[fd7a:115c:a1e0::1]'; do # check-private-data: allow
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
  for a in 192.168.0.10 fd7a:115c:a1e0::1; do # check-private-data: allow
    td td_resolve_controllers "$a"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Not a Tailscale address"* ]] || false
  done
  # A Tailscale IPv6 entry already in the whitelist is dropped; the 100.x one is kept.
  td td_resolve_controllers '' '100.64.0.11,fd7a:115c:a1e0::1' # check-private-data: allow
  [ "$status" -eq 0 ]
  [ "$output" = 100.64.0.11 ]
  td td_resolve_controllers '100.64.0.11,100.64.0.10' '' 100.64.0.10
  [ "$status" -eq 2 ]
  [[ "$output" == *"this Mac's own address"* ]] || false
}

@test "td_host_options turns direct access on with exactly the controllers, and off without" {
  td td_host_options 100.64.0.11 100.64.0.12
  [[ "$output" == *$'whitelist=100.64.0.11,100.64.0.12\ndirect-server=Y'* ]] || false
  td td_host_options
  [[ "$output" == *'direct-server=N'* ]] || false
  [[ "$output" != *'whitelist='* ]] || false
}

@test "td_host_options always uses no public servers and the permanent password only" {
  td td_host_options
  for want in custom-rendezvous-server=127.0.0.1 relay-server=127.0.0.1 verification-method=use-permanent-password \
    approve-mode=password enable-lan-discovery=N; do
    [[ $'\n'"$output"$'\n' == *$'\n'"$want"$'\n'* ]] || false
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
  [[ "$output" != *FAIL* ]] || false
  [[ "$output" == *PASS* ]] || false
}

@test "td_host_findings passes a whitelisted controller with direct access on" {
  td_sh "printf '%s\nwhitelist=100.64.0.11\ndirect-server=Y\n' '$good' | td_host_findings '' 100.64.0.10"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]] || false
  [[ "$output" == *$'PASS\tRustDesk setting whitelist'* ]] || false
  [[ "$output" == *$'PASS\tRustDesk setting direct-server'* ]] || false
  [[ "$output" == *$'PASS\tWhitelist entry \'100.64.0.11\' is one Tailscale address'* ]] || false
}

@test "td_host_findings fails a whitelist that differs from the given controller" {
  td_sh "printf '%s\nwhitelist=\ndirect-server=\n' '$good' | td_host_findings '100.64.0.11' 100.64.0.10"
  [[ "$output" == *$'FAIL\tRustDesk setting whitelist'* ]] || false
  [[ "$output" == *$'FAIL\tRustDesk setting direct-server'* ]] || false
}

@test "td_option_value reads a setting's value, keeping any = after the first" {
  td_sh "printf 'whitelist=100.64.0.11\nrelay-server=a=b\ndirect-server=\n' | td_option_value relay-server"
  [ "$output" = 'a=b' ]
  td_sh "printf 'whitelist=100.64.0.11\n' | td_option_value direct-server"
  [ -z "$output" ]
  td_sh "printf 'not-whitelist=x\nwhitelist=100.64.0.11\n' | td_option_value whitelist"
  [ "$output" = 100.64.0.11 ]
}

@test "the Mac and Windows scripts set the same fixed RustDesk settings (all but the whitelist and direct IP access)" {
  win=$(sed -n "s/^ *'\([a-z-]*\)' *= *'\([^']*\)'.*/\1=\2/p" "$ROOT/scripts/windows/tailnet-desk.psm1" | sort)
  td td_host_options
  mac=$(printf '%s\n' "$output" | grep -v '^direct-server=' | sort)
  [ -n "$win" ]
  [ "$mac" = "$win" ]
}

@test "td_host_findings fails a range left in the whitelist while direct access is off" {
  td_sh "printf '%s\nwhitelist=100.64.0.0/10\ndirect-server=\n' '$good' | td_host_findings '' 100.64.0.10"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'FAIL\tWhitelist entry \'100.64.0.0/10\' is one Tailscale address'* ]] || false
}

@test "td_host_findings fails an empty whitelist while direct access is on" {
  td_sh "printf '%s\nwhitelist=\ndirect-server=Y\n' '$good' | td_host_findings '' 100.64.0.10"
  [[ "$output" == *$'FAIL\tWhitelist is not empty while direct IP access is on'* ]] || false
}

@test "td_host_findings fails this Mac's own address in the whitelist" {
  td_sh "printf '%s\nwhitelist=100.64.0.10\ndirect-server=\n' '$good' | td_host_findings '' 100.64.0.10"
  [[ "$output" == *$'FAIL\tWhitelist doesn\'t include this Mac\'s own address'* ]] || false
}

@test "td_host_findings reports an invalid given controller and a whitelist that differs from the given ones" {
  td_sh "printf '%s\nwhitelist=100.64.0.11\ndirect-server=Y\n' '$good' | td_host_findings '192.168.0.10' ''"
  [[ "$output" == *$'FAIL\tGiven controller address \'192.168.0.10\' is one Tailscale address'* ]] || false
  td_sh "printf '%s\nwhitelist=100.64.0.11\ndirect-server=Y\n' '$good' | td_host_findings '100.64.0.12' ''"
  [[ "$output" == *$'FAIL\tRustDesk setting whitelist'* ]] || false
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
  [[ "$output" == *'FAIL  b  (x)'* ]] || false
  td_sh "printf '' | td_print_findings"
  [ "$status" -ne 0 ]
  [[ "$output" == *'No checks ran'* ]] || false
}

@test "td_pf_rules lets Tailscale in on IPv4 and IPv6 before blocking the port everywhere else" {
  td td_pf_rules
  [ "$(sed -n 2p <<< "$output")" = 'pass in quick inet proto tcp from 100.64.0.0/10 to 100.64.0.0/10 port 21118' ]
  [ "$(sed -n 3p <<< "$output")" = 'pass in quick inet6 proto tcp from fd7a:115c:a1e0::/48 to fd7a:115c:a1e0::/48 port 21118' ] # check-private-data: allow
  [ "$(sed -n 4p <<< "$output")" = 'block drop in quick proto tcp from any to any port 21118' ]
}

@test "td_pf_loader takes its own pf reference, never stops pf, and is valid bash" {
  td td_pf_loader
  [[ "$output" == *'/sbin/pfctl -E'* ]] || false
  [[ "$output" == *"-a 'com.apple/tailnet-desk' -f"* ]] || false
  [[ "$output" != *'pfctl -d'* ]] || false
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/load-pf.sh"
  /bin/bash -n "$BATS_TEST_TMPDIR/load-pf.sh"
}

# Writes the real loader text to $BATS_TEST_TMPDIR/load-pf.sh with stand-ins for pfctl and sysctl. The pfctl stand-in
# logs its arguments to $PFCTL_LOG and hands out tokens 1001, 1002, ... for -E, or fails -E when $PFCTL_FAIL is set; the
# sysctl stand-in reports the boot time in $FAKE_BOOT (an empty FAKE_BOOT gives output that can't be parsed).
make_loader() {
  dir="$BATS_TEST_TMPDIR/pf"; mkdir -p "$dir"
  cat > "$BATS_TEST_TMPDIR/pfctl" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PFCTL_LOG"
if [ "$1" = -E ]; then
  [ -z "${PFCTL_FAIL-}" ] || { echo 'pfctl: DIOCSTARTREF: Permission denied' >&2; exit 1; }
  n=$(( $(cat "$PFCTL_COUNT" 2> /dev/null || echo 1000) + 1 )); echo "$n" > "$PFCTL_COUNT"
  printf 'No ALTQ support in kernel\npf enabled\nToken : %s\n' "$n"
fi
STUB
  cat > "$BATS_TEST_TMPDIR/sysctl" << 'STUB'
#!/bin/bash
if [ -n "${FAKE_BOOT-}" ]; then echo "{ sec = $FAKE_BOOT, usec = 5 } Sun Nov 15 11:04:24 2026"; else echo 'kern.boottime: unknown'; fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/pfctl" "$BATS_TEST_TMPDIR/sysctl"
  td td_pf_loader
  printf '%s\n' "$output" | sed -e "s#/sbin/pfctl#$BATS_TEST_TMPDIR/pfctl#g" -e "s#/usr/sbin/sysctl#$BATS_TEST_TMPDIR/sysctl#g" \
    -e "s#^dir=.*#dir='$dir'#" -e "s#^log=.*#log='$dir/load-pf.log'#" > "$BATS_TEST_TMPDIR/load-pf.sh"
  export PFCTL_LOG="$BATS_TEST_TMPDIR/pfctl.log" PFCTL_COUNT="$BATS_TEST_TMPDIR/count"
}

@test "the pf loader saves its token with the boot, and a re-run takes the new reference before releasing the old one" {
  make_loader
  FAKE_BOOT=111 /bin/bash "$BATS_TEST_TMPDIR/load-pf.sh"
  [ "$(cat "$dir/token")" = '1001 111' ]
  FAKE_BOOT=111 /bin/bash "$BATS_TEST_TMPDIR/load-pf.sh"
  [ "$(cat "$dir/token")" = '1002 111' ]
  # In order: the second run takes 1002, then releases 1001, so pf never goes off in between.
  [ "$(grep -v -- '^-a ' "$PFCTL_LOG" | tr '\n' '|')" = '-E|-E|-X 1001|' ]
  # After a restart (a new boot time), the old token is dropped, not released.
  FAKE_BOOT=222 /bin/bash "$BATS_TEST_TMPDIR/load-pf.sh"
  [ "$(cat "$dir/token")" = '1003 222' ]
  [ "$(grep -c -- '^-X' "$PFCTL_LOG")" -eq 1 ]
  run grep -q -- '^-d' "$PFCTL_LOG"
  [ "$status" -ne 0 ]
}

@test "when pfctl -E gives no token, the loader stops with pfctl's error, keeps the old token and loads no rules" {
  make_loader
  printf '999 111\n' > "$dir/token"
  PFCTL_FAIL=1 FAKE_BOOT=111 run /bin/bash "$BATS_TEST_TMPDIR/load-pf.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'pfctl -E gave no token'*'Permission denied'* ]] || false
  [ "$(cat "$dir/token")" = '999 111' ]
  run grep -q -- '^-X' "$PFCTL_LOG"
  [ "$status" -ne 0 ]
  run grep -q -- '^-a ' "$PFCTL_LOG"
  [ "$status" -ne 0 ]
}

@test "when the boot time can't be read, the loader stops before touching pf and keeps the old token" {
  make_loader
  printf '999 111\n' > "$dir/token"
  FAKE_BOOT= run /bin/bash "$BATS_TEST_TMPDIR/load-pf.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't read the boot time"* ]] || false
  [ ! -e "$PFCTL_LOG" ]
  [ "$(cat "$dir/token")" = '999 111' ]
}

@test "the pf loader empties its log before a run, and keeps this run's error" {
  make_loader
  printf 'old error\n' > "$dir/load-pf.log"
  FAKE_BOOT=111 /bin/bash "$BATS_TEST_TMPDIR/load-pf.sh" 2>> "$dir/load-pf.log"
  [ ! -s "$dir/load-pf.log" ]
  printf 'old error\n' > "$dir/load-pf.log"
  FAKE_BOOT= /bin/bash "$BATS_TEST_TMPDIR/load-pf.sh" 2>> "$dir/load-pf.log" || true
  grep -q "Couldn't read the boot time" "$dir/load-pf.log"
  run grep -q 'old error' "$dir/load-pf.log"
  [ "$status" -ne 0 ]
}

@test "td_pf_token_to_release_from_file treats a missing token file as nothing saved, under set -euo pipefail" {
  td td_pf_token_to_release_from_file "$BATS_TEST_TMPDIR/no-such-token" 111
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '1001 111\n' > "$BATS_TEST_TMPDIR/token"
  td td_pf_token_to_release_from_file "$BATS_TEST_TMPDIR/token" 111
  [ "$status" -eq 0 ]
  [ "$output" = 1001 ]
  td td_pf_token_to_release_from_file "$BATS_TEST_TMPDIR/token" 222
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "td_pf_token_to_release_from_file says it can't release when the token file can't be read" {
  [ "$(id -u)" -ne 0 ] || skip 'root can read any file'
  printf '1001 111\n' > "$BATS_TEST_TMPDIR/token"
  chmod 000 "$BATS_TEST_TMPDIR/token"
  td td_pf_token_to_release_from_file "$BATS_TEST_TMPDIR/token" 111
  chmod 600 "$BATS_TEST_TMPDIR/token"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "td_pf_token_to_release releases only this boot's token, and says when it can't" {
  td_sh "printf '1001 111\n' | td_pf_token_to_release 111"
  [ "$status" -eq 0 ]
  [ "$output" = 1001 ]
  td_sh "printf '1001 111\n' | td_pf_token_to_release 222"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  td_sh "printf '1001 111\n' | td_pf_token_to_release ''"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  td_sh "printf '' | td_pf_token_to_release 111"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "td_boot_from_sysctl and td_pf_token_for_boot only accept a token from the same, known boot" {
  td_sh "printf '{ sec = 123456, usec = 435243 } Sun Nov 15 11:04:24 2026\n' | td_boot_from_sysctl"
  [ "$output" = 123456 ]
  td_sh "printf 'garbage\n' | td_boot_from_sysctl"
  [ -z "$output" ]
  td_sh "printf '' | td_boot_from_sysctl"
  [ -z "$output" ]
  td_sh "printf '1001 111\n' | td_pf_token_for_boot 111"
  [ "$output" = 1001 ]
  td_sh "printf '1001 111\n' | td_pf_token_for_boot 222"
  [ -z "$output" ]
  td_sh "printf '1001\n' | td_pf_token_for_boot 111"
  [ -z "$output" ]
  td_sh "printf '1001 \n' | td_pf_token_for_boot ''"
  [ -z "$output" ]
  td_sh "printf 'x1 111\n' | td_pf_token_for_boot 111"
  [ -z "$output" ]
}

@test "both Mac guides check RustDesk's signature with the script's own requirement" {
  td td_rustdesk_requirement
  want=$output
  for guide in host-mac controller-mac; do
    grep -qF -- "-R='$want'" "$ROOT/docs/$guide.md"
  done
}

@test "td_pf_plist is a valid property list that runs the loader at boot" {
  td td_pf_plist
  [[ "$output" == *'<key>RunAtLoad</key><true/>'* ]] || false
  [[ "$output" == *'load-pf.sh'* ]] || false
  [[ "$output" == *'<key>StandardErrorPath</key><string>/Library/Application Support/tailnet-desk/load-pf.log</string>'* ]] || false
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

@test "td_rustdesk_requirement asks for an Apple-issued certificate for RustDesk's team" {
  td td_rustdesk_requirement
  [ "$output" = 'anchor apple generic and certificate leaf[subject.OU] = "HZF9JMC8YN"' ]
}

@test "td_signed_by_rustdesk refuses something not signed by RustDesk's team" {
  command -v codesign > /dev/null || skip 'codesign exists only on macOS'
  td td_signed_by_rustdesk /bin/ls
  [ "$status" -ne 0 ]
  printf 'not signed\n' > "$BATS_TEST_TMPDIR/file"
  td td_signed_by_rustdesk "$BATS_TEST_TMPDIR/file"
  [ "$status" -ne 0 ]
}

@test "td_rustdesk_asset names the right disk image and hash for each Mac type" {
  td td_rustdesk_asset arm64
  [ "$(sed -n 1p <<< "$output")" = rustdesk-1.5.3-aarch64.dmg ]
  [ "$(sed -n 2p <<< "$output" | wc -c | tr -d ' ')" -eq 65 ]
  td td_rustdesk_asset x86_64
  [ "$(sed -n 1p <<< "$output")" = rustdesk-1.5.3-x86_64.dmg ]
  [ "$(sed -n 2p <<< "$output" | wc -c | tr -d ' ')" -eq 65 ]
  td td_rustdesk_asset sparc
  [ "$status" -eq 2 ]
}

@test "the Mac and Windows scripts pin the same RustDesk version" {
  mac=$(sed -n "s/^TD_RUSTDESK_VERSION='\(.*\)'.*/\1/p" "$LIB")
  win=$(sed -n "s/^ *RustDeskVersion *= *'\([^']*\)'.*/\1/p" "$ROOT/scripts/windows/tailnet-desk.psm1")
  [ -n "$mac" ]
  [ "$mac" = "$win" ]
}

@test "the Mac and Windows scripts pin the same Tailscale version" {
  mac=$(sed -n "s/^TD_TAILSCALE_VERSION='\(.*\)'.*/\1/p" "$LIB")
  win=$(sed -n "s/^ *TailscaleVersion *= *'\([^']*\)'.*/\1/p" "$ROOT/scripts/windows/tailnet-desk.psm1")
  [ -n "$mac" ]
  [ "$mac" = "$win" ]
}

@test "td_tailscale_pkg_name names the pinned installer, and its SHA-256 is pinned" {
  td td_tailscale_pkg_name
  [ "$output" = Tailscale-1.104.4-macos.pkg ]
  td_sh 'printf "%s" "$TD_TAILSCALE_PKG_SHA256"'
  [[ "$output" =~ ^[0-9a-f]{64}$ ]] || false
}

@test "td_team_requirement asks for an Apple-issued certificate for Tailscale's team" {
  td_sh 'td_team_requirement "$TD_TAILSCALE_TEAM"'
  [ "$output" = 'anchor apple generic and certificate leaf[subject.OU] = "W5364U7YZB"' ]
}

# pkgutil --check-signature's output for Tailscale's installer, with the fingerprints left out.
pkgutil_output() {
  printf '%s\n' \
    'Package "Tailscale-1.104.4-macos.pkg":' \
    "   Status: ${1:-signed by a developer certificate issued by Apple for distribution}" \
    "   Notarization: ${2:-trusted by the Apple notary service}" \
    '   Certificate Chain:' \
    "    1. ${3:-Developer ID Installer: Tailscale Inc. (W5364U7YZB)}" \
    '    2. Developer ID Certification Authority' \
    '    3. Apple Root CA'
}

@test "td_pkg_signed_by_team accepts a notarized installer signed by the team's Developer ID Installer certificate" {
  pkgutil_output > "$BATS_TEST_TMPDIR/sig"
  td_sh "td_pkg_signed_by_team W5364U7YZB < '$BATS_TEST_TMPDIR/sig'"
  [ "$status" -eq 0 ]
  # Trailing spaces after the certificate name don't matter.
  pkgutil_output '' '' 'Developer ID Installer: Tailscale Inc. (W5364U7YZB)   ' > "$BATS_TEST_TMPDIR/spaces"
  td_sh "td_pkg_signed_by_team W5364U7YZB < '$BATS_TEST_TMPDIR/spaces'"
  [ "$status" -eq 0 ]
}

@test "td_pkg_signed_by_team refuses another team, no notarization, an untrusted signature and no output" {
  pkgutil_output '' '' 'Developer ID Installer: Someone Else (ABCDE12345)' > "$BATS_TEST_TMPDIR/other"
  pkgutil_output '' '' 'Developer ID Installer: Fake (W5364U7YZB) Ltd (ABCDE12345)' > "$BATS_TEST_TMPDIR/inside"
  pkgutil_output '' 'none' > "$BATS_TEST_TMPDIR/unnotarized"
  pkgutil_output 'signed by untrusted certificate' > "$BATS_TEST_TMPDIR/untrusted"
  pkgutil_output '' '' 'Developer ID Application: Tailscale Inc. (W5364U7YZB)' > "$BATS_TEST_TMPDIR/appcert"
  : > "$BATS_TEST_TMPDIR/empty"
  for f in other inside unnotarized untrusted appcert empty; do
    td_sh "td_pkg_signed_by_team W5364U7YZB < '$BATS_TEST_TMPDIR/$f'"
    [ "$status" -ne 0 ] || { echo "accepted: $f"; false; }
  done
  # The team named only further up the chain doesn't count either.
  printf '%s\n' '   Status: signed by a developer certificate issued by Apple for distribution' \
    '   Notarization: trusted by the Apple notary service' \
    '    1. Developer ID Installer: Someone Else (ABCDE12345)' \
    '    2. Developer ID Installer: Tailscale Inc. (W5364U7YZB)' > "$BATS_TEST_TMPDIR/second"
  td_sh "td_pkg_signed_by_team W5364U7YZB < '$BATS_TEST_TMPDIR/second'"
  [ "$status" -ne 0 ]
}

@test "td_signed_by_tailscale refuses something not signed by Tailscale's team" {
  command -v codesign > /dev/null || skip 'codesign exists only on macOS'
  td td_signed_by_tailscale /bin/ls
  [ "$status" -ne 0 ]
  printf 'not signed\n' > "$BATS_TEST_TMPDIR/file"
  td td_signed_by_tailscale "$BATS_TEST_TMPDIR/file"
  [ "$status" -ne 0 ]
}

# Stand-ins for the programs the installers run by fixed path. Each logs "name args" to $STUB_LOG. curl writes
# $CURL_BODY to its -o file (or fails when CURL_FAIL is set), pkgutil prints $PKGUTIL_OUT, codesign fails for a path
# matching the pattern $CODESIGN_FAIL (or for every path when CODESIGN_EXIT=1), sudo exits with $SUDO_EXIT (0 unless
# set), hdiutil attach exits with $ATTACH_EXIT, mktemp makes its folder under $T/tmp, and open only logs (hdiutil attach makes the mount folder hold a
# RustDesk.app). The real shasum hashes the download, so a test sets $WANT_SHA to the hash it wants pinned.
make_stubs() {
  B="$BATS_TEST_TMPDIR/bin"; T="$BATS_TEST_TMPDIR/sys"; mkdir -p "$B" "$T/tmp"
  printf '#!/bin/bash\nprintf "open %%s\\n" "$*" >> "$STUB_LOG"\n' > "$B/open"
  printf '#!/bin/bash\nprintf "sudo %%s\\n" "$*" >> "$STUB_LOG"\nexit "${SUDO_EXIT:-0}"\n' > "$B/sudo"
  cat > "$B/curl" << 'STUB'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
[ -z "${CURL_FAIL-}" ] || exit 22
while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { printf '%s' "$CURL_BODY" > "$2"; exit 0; }; shift; done
STUB
  cat > "$B/pkgutil" << 'STUB'
#!/bin/bash
printf 'pkgutil %s\n' "$*" >> "$STUB_LOG"
printf '%s\n' "${PKGUTIL_OUT-}"
STUB
  cat > "$B/codesign" << 'STUB'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$STUB_LOG"
for last in "$@"; do :; done
# shellcheck disable=SC2254 # the pattern is meant to match
case "$last" in ${CODESIGN_FAIL:-//none//}) exit 1 ;; esac
exit "${CODESIGN_EXIT:-0}"
STUB
  # macOS's mktemp ignores TMPDIR, so this one makes the private download folder under $T/tmp, where a test can look.
  printf '#!/bin/bash\nexec /usr/bin/mktemp -d "$T/tmp/dl.XXXXXX"\n' > "$B/mktemp"
  cat > "$B/hdiutil" << 'STUB'
#!/bin/bash
printf 'hdiutil %s\n' "$*" >> "$STUB_LOG"
if [ "$1" = attach ]; then
  [ "${ATTACH_EXIT:-0}" -eq 0 ] || exit "$ATTACH_EXIT"
  while [ "$#" -gt 1 ]; do [ "$1" = -mountpoint ] && mkdir -p "$2/RustDesk.app"; shift; done
fi
exit 0
STUB
  chmod +x "$B"/*
  export B T STUB_LOG="$BATS_TEST_TMPDIR/stub.log" LIB TMPDIR="$T/tmp" CURL_BODY='installer bytes'
  : > "$STUB_LOG"
}

# Runs installer function $1 from the library with its fixed-path programs pointed at the stand-ins, and Tailscale and
# RustDesk "installed" under $T instead of /Applications.
run_installer() {
  run /bin/bash -c '
    set -euo pipefail
    . "$LIB"
    TD_TAILSCALE_APP="$T/Tailscale.app"; TD_RUSTDESK_APP="$T/RustDesk.app"
    if [ -n "${WANT_SHA-}" ]; then
      TD_TAILSCALE_PKG_SHA256=$WANT_SHA; TD_RUSTDESK_SHA256_ARM64=$WANT_SHA; TD_RUSTDESK_SHA256_X86_64=$WANT_SHA
    fi
    eval "$(declare -f | sed -e "s#/usr/bin/curl#$B/curl#g" -e "s#/usr/sbin/pkgutil#$B/pkgutil#g" \
      -e "s#/usr/bin/sudo#$B/sudo#g" -e "s#/usr/bin/open#$B/open#g" -e "s#/usr/bin/codesign#$B/codesign#g" \
      -e "s#/usr/bin/hdiutil#$B/hdiutil#g" -e "s#/usr/bin/mktemp#$B/mktemp#g")"
    "$1"
  ' run_installer "$1"
}

good_sha() { printf '%s' "$CURL_BODY" | /usr/bin/shasum -a 256 | awk '{ print $1 }'; }

@test "td_install_tailscale installs nothing, runs nothing with sudo and leaves no download when the hash differs" {
  make_stubs
  export WANT_SHA=$(printf 'x%.0s' {1..64})
  run_installer td_install_tailscale
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match the pinned one"* ]] || false
  ! grep -q '^sudo' "$STUB_LOG" || false
  ! grep -q '^pkgutil' "$STUB_LOG" || false
  [ -z "$(ls -A "$T/tmp")" ]
}

@test "td_install_tailscale installs nothing when the installer isn't signed and notarized for Tailscale's team" {
  make_stubs
  export WANT_SHA=$(good_sha)
  export PKGUTIL_OUT="$(pkgutil_output '' '' 'Developer ID Installer: Someone Else (ABCDE12345)')"
  run_installer td_install_tailscale
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't signed by Tailscale's Apple team and notarized"* ]] || false
  ! grep -q '^sudo' "$STUB_LOG" || false
  [ -z "$(ls -A "$T/tmp")" ]
}

@test "td_install_tailscale installs a checked installer with macOS's installer, then checks the app and cleans up" {
  make_stubs
  export WANT_SHA=$(good_sha) PKGUTIL_OUT="$(pkgutil_output)"
  run_installer td_install_tailscale
  [ "$status" -eq 0 ]
  grep -q "^sudo /usr/sbin/installer -pkg .*/Tailscale-1.104.4-macos.pkg -target /" "$STUB_LOG"
  grep -q "^codesign .*W5364U7YZB.* $T/Tailscale.app" "$STUB_LOG"
  [ -z "$(ls -A "$T/tmp")" ]
}

@test "td_install_tailscale stops when the installed app fails its signature check" {
  make_stubs
  export WANT_SHA=$(good_sha) PKGUTIL_OUT="$(pkgutil_output)" CODESIGN_EXIT=1
  run_installer td_install_tailscale
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't signed by Tailscale's Apple team after installing"* ]] || false
  ! grep -q '^open' "$STUB_LOG" || false
}

@test "the installers clean up and run nothing with sudo when the download fails" {
  make_stubs
  export CURL_FAIL=1
  for f in td_install_tailscale td_install_rustdesk; do
    run_installer "$f"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Couldn't download"* ]] || false
    [ -z "$(ls -A "$T/tmp")" ]
  done
  ! grep -q '^sudo' "$STUB_LOG" || false
}

@test "td_install_tailscale cleans up and says so when macOS's installer fails" {
  make_stubs
  export WANT_SHA=$(good_sha) PKGUTIL_OUT="$(pkgutil_output)" SUDO_EXIT=1
  run_installer td_install_tailscale
  [ "$status" -eq 1 ]
  [[ "$output" == *"macOS's installer couldn't install Tailscale"* ]] || false
  [ -z "$(ls -A "$T/tmp")" ]
  ! grep -q '^open' "$STUB_LOG" || false
}

@test "the installers keep what's already installed and download nothing" {
  make_stubs
  mkdir -p "$T/Tailscale.app/Contents/MacOS" "$T/RustDesk.app/Contents/MacOS"
  for exe in "$T/Tailscale.app/Contents/MacOS/Tailscale" "$T/RustDesk.app/Contents/MacOS/RustDesk"; do
    printf '#!/bin/bash\n' > "$exe"; chmod +x "$exe"
  done
  run_installer td_install_tailscale
  [ "$status" -eq 0 ]; [[ "$output" == *'Tailscale is already installed.'* ]] || false
  run_installer td_install_rustdesk
  [ "$status" -eq 0 ]; [[ "$output" == *'RustDesk is already installed.'* ]] || false
  ! grep -q '^curl' "$STUB_LOG" || false
}

@test "td_install_rustdesk copies nothing and leaves no download when the hash or the disk image's signature fails" {
  make_stubs
  export WANT_SHA=$(printf 'x%.0s' {1..64})
  run_installer td_install_rustdesk
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match the pinned one"* ]] || false
  ! grep -q '^sudo\|^hdiutil' "$STUB_LOG" || false
  [ -z "$(ls -A "$T/tmp")" ]
  : > "$STUB_LOG"
  export WANT_SHA=$(good_sha) CODESIGN_EXIT=1
  run_installer td_install_rustdesk
  [ "$status" -eq 1 ]
  [[ "$output" == *"disk image isn't signed by RustDesk's Apple team"* ]] || false
  ! grep -q '^sudo\|^hdiutil' "$STUB_LOG" || false
  [ -z "$(ls -A "$T/tmp")" ]
}

@test "td_install_rustdesk copies nothing when the disk image won't open or the app inside isn't RustDesk's own" {
  make_stubs
  export WANT_SHA=$(good_sha) ATTACH_EXIT=1
  run_installer td_install_rustdesk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't open the disk image"* ]] || false
  ! grep -q '^sudo' "$STUB_LOG" || false
  [ -z "$(ls -A "$T/tmp")" ]
  : > "$STUB_LOG"
  export ATTACH_EXIT=0 CODESIGN_FAIL='*/mount/RustDesk.app'
  run_installer td_install_rustdesk
  [ "$status" -eq 1 ]
  [[ "$output" == *"app in the disk image isn't signed by RustDesk's Apple team"* ]] || false
  ! grep -q '^sudo' "$STUB_LOG" || false
  grep -q '^hdiutil detach' "$STUB_LOG"
  [ -z "$(ls -A "$T/tmp")" ]
}

@test "td_install_rustdesk copies a checked app to Applications, detaches, cleans up and checks the copy" {
  make_stubs
  export WANT_SHA=$(good_sha)
  run_installer td_install_rustdesk
  [ "$status" -eq 0 ]
  grep -q "^sudo /usr/bin/ditto .*/mount/RustDesk.app $T/RustDesk.app\$" "$STUB_LOG"
  grep -q '^hdiutil detach' "$STUB_LOG"
  [ "$(grep '^codesign' "$STUB_LOG" | tail -n 1)" = "codesign --verify --strict -R=anchor apple generic and certificate leaf[subject.OU] = \"HZF9JMC8YN\" $T/RustDesk.app" ]
  [ -z "$(ls -A "$T/tmp")" ]
  : > "$STUB_LOG"
  export SUDO_EXIT=1
  run_installer td_install_rustdesk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't copy RustDesk to Applications"* ]] || false
  grep -q '^hdiutil detach' "$STUB_LOG"
  [ -z "$(ls -A "$T/tmp")" ]
}

@test "td_install_rustdesk refuses an installed RustDesk that isn't RustDesk's own, and downloads nothing" {
  make_stubs
  mkdir -p "$T/RustDesk.app/Contents/MacOS"
  printf '#!/bin/bash\n' > "$T/RustDesk.app/Contents/MacOS/RustDesk"; chmod +x "$T/RustDesk.app/Contents/MacOS/RustDesk"
  export CODESIGN_EXIT=1
  run_installer td_install_rustdesk
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't signed by RustDesk's Apple team. Delete it"* ]] || false
  ! grep -q '^curl' "$STUB_LOG" || false
}

@test "td_rustdesk_get and td_rustdesk_set never run a RustDesk that fails its signature check with sudo" {
  make_stubs
  mkdir -p "$T/RustDesk.app/Contents/MacOS"
  printf '#!/bin/bash\n' > "$T/RustDesk.app/Contents/MacOS/RustDesk"; chmod +x "$T/RustDesk.app/Contents/MacOS/RustDesk"
  export CODESIGN_EXIT=1
  for f in 'td_rustdesk_get whitelist' 'td_rustdesk_set whitelist=100.64.0.11'; do
    run /bin/bash -c '
      set -euo pipefail
      . "$LIB"; TD_RUSTDESK_APP="$T/RustDesk.app"
      eval "$(declare -f | sed -e "s#/usr/bin/sudo#$B/sudo#g" -e "s#/usr/bin/codesign#$B/codesign#g")"
      $1' x "$f"
    [ "$status" -eq 1 ]
    [[ "$output" == *"isn't signed by RustDesk's Apple team, so it isn't run"* ]] || false
  done
  ! grep -q '^sudo' "$STUB_LOG" || false
}

@test "test-from-controller.sh refuses bad addresses before testing anything" {
  run /bin/bash "$ROOT/scripts/mac/test-from-controller.sh" --host-tailscale-ip 192.168.0.10
  [ "$status" -eq 2 ]
  [[ "$output" == *'Not a Tailscale address'* ]] || false
  run /bin/bash "$ROOT/scripts/mac/test-from-controller.sh" --host-tailscale-ip 100.64.0.10 --host-home-ip 127.0.0.1
  [ "$status" -eq 2 ]
  [[ "$output" == *'Not a home network address'* ]] || false
}

@test "the scripts refuse unknown options and print their usage on --help" {
  for s in install-host test-host test-from-controller enable-pf undo-pf; do
    run /bin/bash "$ROOT/scripts/mac/$s.sh" --no-such-option
    [ "$status" -eq 2 ]
    [[ "$output" == *'Unknown option: --no-such-option'* ]] || false
    run /bin/bash "$ROOT/scripts/mac/$s.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'Usage:'* ]] || false
    [[ "$output" != *'set -'* ]] || false
    [[ "$output" != *'#'* ]] || false
  done
}

@test "the scripts refuse an option that's missing its address" {
  run /bin/bash "$ROOT/scripts/mac/install-host.sh" --controller-ip
  [ "$status" -eq 2 ]
  [[ "$output" == *'needs an address'* ]] || false
  run /bin/bash "$ROOT/scripts/mac/test-host.sh" --controller-ip
  [ "$status" -eq 2 ]
  [[ "$output" == *'--controller-ip needs an address'* ]] || false
  run /bin/bash "$ROOT/scripts/mac/test-from-controller.sh" --host-tailscale-ip
  [ "$status" -eq 2 ]
  [[ "$output" == *'--host-tailscale-ip needs an address'* ]] || false
  run /bin/bash "$ROOT/scripts/mac/test-from-controller.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *'Not a Tailscale address'* ]] || false
}

@test "install-host.sh refuses an invalid controller address before changing anything" {
  run /bin/bash "$ROOT/scripts/mac/install-host.sh" --controller-ip 100.64.0.0/10
  [ "$status" -eq 2 ]
  [[ "$output" == *'Not a Tailscale address'* ]] || false
  [[ "$output" != *'Step 1'* ]] || false
}
