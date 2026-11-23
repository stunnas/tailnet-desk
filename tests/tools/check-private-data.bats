#!/usr/bin/env bats
# Tests for tools/check-private-data.sh. Run: bats tests/tools
# Every address, name and ID below is made up.

setup() {
  CHECK="$BATS_TEST_DIRNAME/../../tools/check-private-data.sh"
  TMP="$(mktemp -d)"
  git -C "$TMP" init -q
  cd "$TMP"
}

teardown() {
  rm -rf "$TMP"
}

check_text() {
  printf '%s\n' "$1" > "$TMP/file.md"
  run "$CHECK" "$TMP/file.md"
}

@test "passes the example addresses and fixed values" {
  check_text 'Host 100.64.0.10, controllers 100.64.0.11 and 100.64.0.12; home 192.168.0.10; range 100.64.0.0/10 to 100.127.255.255; 127.0.0.1 and 0.0.0.0.'
  [ "$status" -eq 0 ]
}

@test "passes version numbers, placeholders, hashes, ports, dates and times" {
  check_text 'RustDesk 1.5.3, Tailscale 1.104.7, 100.x.y.z, 192.168.x.x, sha256 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8, ports 21118 and 21119, on 2026-11-14 at 08:43.'
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

@test "fails a global IPv6 address, full and compressed" {
  check_text 'Connect to [2001:db8:1:2:3:4:5:6]:21118'
  [ "$status" -eq 1 ]
  [[ "$output" == *"IPv6 address"* ]]
  check_text 'or [2001:db8::1]'
  [ "$status" -eq 1 ]
}

@test "fails a Tailscale IPv6 address" {
  check_text 'Its IPv6 is fd7a:115c:a1e0::1234:5678'
  [ "$status" -eq 1 ]
  [[ "$output" == *"IPv6 address"* ]]
}

@test "fails a MagicDNS name" {
  check_text 'Connect to my-desktop.tail1234.ts.net'
  [ "$status" -eq 1 ]
  [[ "$output" == *"MagicDNS name"* ]]
}

@test "fails 9- and 10-digit RustDesk IDs, plain and spaced" {
  for id in 123456789 1234567890 '123 456 789' '1 234 567 890'; do
    check_text "My ID is $id"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RustDesk ID"* ]]
  done
}

@test "passes a five-part version number, but fails a four-part one, which reads as an address" {
  check_text 'Build 1.2.3.4.5'
  [ "$status" -eq 0 ]
  check_text 'Build 1.2.3.4'
  [ "$status" -eq 1 ]
}

@test "scans UTF-8 text with non-ASCII characters, in the C and UTF-8 locales" {
  printf 'Settings \342\206\222 Security, host 100.99.88.77\n' > "$TMP/arrow.md"
  LC_ALL=C run "$CHECK" "$TMP/arrow.md"
  [ "$status" -eq 1 ]
  LC_ALL=C.UTF-8 run "$CHECK" "$TMP/arrow.md"
  [ "$status" -eq 1 ]
}

@test "scans text that isn't valid UTF-8" {
  printf 'caf\351, host 100.99.88.77\n' > "$TMP/latin1.md"
  LC_ALL=C.UTF-8 run "$CHECK" "$TMP/latin1.md"
  [ "$status" -eq 1 ]
}

@test "passes 8- and 11-digit numbers" {
  check_text 'Numbers 12345678 and 12345678901'
  [ "$status" -eq 0 ]
}

@test "skips a line marked as made-up test data" {
  check_text "'100.63.255.255' # check-private-data: allow"
  [ "$status" -eq 0 ]
}

@test "reports the file and line" {
  printf 'fine\nhost 100.99.88.77\n' > "$TMP/two.md"
  run "$CHECK" "$TMP/two.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"two.md:2:"* ]]
}

@test "fails when a named file doesn't exist" {
  run "$CHECK" "$TMP/missing.md"
  [ "$status" -eq 2 ]
}

@test "without arguments, scans tracked files but skips fixtures and binary files" {
  mkdir -p docs tests/fixtures
  printf 'fine\n' > docs/ok.md
  printf 'planted 100.99.88.77\n' > tests/fixtures/planted.md
  printf 'binary\000 host 100.99.88.77\n' > docs/shot.png
  git add -A
  run "$CHECK"
  [ "$status" -eq 0 ]

  printf 'host 100.99.88.77\n' > docs/leak.md
  git add docs/leak.md
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/leak.md:1:"* ]]
}

@test "without arguments, works from a subfolder and fails when nothing is tracked" {
  run "$CHECK"
  [ "$status" -eq 2 ]
  mkdir -p docs && printf 'host 100.99.88.77\n' > docs/leak.md && git add -A
  cd docs
  run "$CHECK"
  [ "$status" -eq 1 ]
}

@test "without arguments, skips tracked symlinks" {
  printf 'host 100.99.88.77\n' > "$BATS_TEST_TMPDIR/outside.md"
  ln -s "$BATS_TEST_TMPDIR/outside.md" linked.md
  printf 'fine\n' > ok.md
  git add -A
  run "$CHECK"
  [ "$status" -eq 0 ]
}
