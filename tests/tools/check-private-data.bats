#!/usr/bin/env bats
# Tests for tools/check-private-data.sh. Run: bats tests/tools

setup() {
  CHECK="$BATS_TEST_DIRNAME/../../tools/check-private-data.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

check_text() {
  printf '%s\n' "$1" > "$TMP/file.md"
  run "$CHECK" "$TMP/file.md"
}

@test "passes the example addresses and fixed values" {
  check_text 'Connect to 100.64.0.10 or 100.64.0.11; home 192.168.0.10; range 100.64.0.0/10; 127.0.0.1 and 0.0.0.0.'
  [ "$status" -eq 0 ]
}

@test "passes version numbers, placeholders and hashes" {
  check_text 'RustDesk 1.5.3, Tailscale 1.104.7, 100.x.y.z, 192.168.x.x, sha256 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'
  [ "$status" -eq 0 ]
}

@test "fails a real-looking Tailscale address" {
  check_text 'My host is 100.99.88.77.'
  [ "$status" -eq 1 ]
  [[ "$output" == *"IPv4 address 100.99.88.77"* ]]
}

@test "fails both addresses in a comma-separated whitelist" {
  check_text 'whitelist = 100.90.1.2,100.90.3.4'
  [ "$status" -eq 1 ]
  [[ "$output" == *"100.90.1.2"* ]]
  [[ "$output" == *"100.90.3.4"* ]]
}

@test "fails a home address inside a command" {
  check_text 'Test-NetConnection 192.168.5.55 -Port 21118'
  [ "$status" -eq 1 ]
}

@test "fails a global IPv6 address" {
  check_text 'Connect to [2001:db8:1:2:3:4:5:6]:21118'
  [ "$status" -eq 1 ]
  [[ "$output" == *"IPv6 address"* ]]
}

@test "fails a 9-digit RustDesk ID" {
  check_text 'My ID is 123456789'
  [ "$status" -eq 1 ]
  [[ "$output" == *"RustDesk ID"* ]]
}

@test "passes port numbers and dates" {
  check_text 'Ports 21118 and 21119, on 2026-11-14 at 08:43.'
  [ "$status" -eq 0 ]
}

@test "reports the file and line" {
  printf 'fine\nhost 100.99.88.77\n' > "$TMP/two.md"
  run "$CHECK" "$TMP/two.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"two.md:2:"* ]]
}
