#!/usr/bin/env bats
# Tests for tools/check-versions.sh. Run: bats tests/tools
# Each test runs a copy of the script in a made-up repo whose pins it writes, so the real pins can change freely.

REAL="$BATS_TEST_DIRNAME/../../tools/check-versions.sh"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/tools" "$TMP/scripts/mac" "$TMP/scripts/windows"
  cp "$REAL" "$TMP/tools/check-versions.sh"
  CHECK="$TMP/tools/check-versions.sh"
  pins 1.5.3 1.104.4
}

teardown() {
  rm -rf "$TMP"
}

# Writes RustDesk $1 and Tailscale $2 into both made-up scripts, laid out as the real ones are; $3 and $4, when given,
# replace the Windows ones.
pins() {
  printf '%s\n' "TD_RUSTDESK_VERSION='$1'" "TD_RUSTDESK_SHA256_ARM64='aa'" "TD_TAILSCALE_VERSION='$2'" \
    > "$TMP/scripts/mac/tailnet-desk.sh"
  printf '%s\n' '$script:Setting = [pscustomobject]@{' "    RustDeskVersion = '${3:-$1}'" \
    "    TailscaleVersion   = '${4:-$2}'" '}' > "$TMP/scripts/windows/tailnet-desk.psm1"
}

@test "reports both up to date, and exits 0" {
  TODAY=2026-11-24 run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'Pinned versions compared with the latest releases on 2026-11-24.' ]
  grep -qF '| RustDesk | 1.5.3 | 1.5.3 (2026-11-09) | Up to date |' <<< "$output"
  grep -qF '| Tailscale | 1.104.4 | 1.104.4 (2026-10-28) | Up to date |' <<< "$output"
  ! grep -q 'To bump a pin' <<< "$output" || false
}

@test "waits on a newer release younger than 14 days, and exits 0" {
  TODAY=2026-11-24 run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.7 2026-11-12T22:56:51Z
  [ "$status" -eq 0 ]
  grep -qF "| Tailscale | 1.104.4 | 1.104.7 (2026-11-12) | Newer, released 12 days ago: due once it's 14 days old |" <<< "$output"
  ! grep -q 'To bump a pin' <<< "$output" || false
}

@test "says a bump is due once a newer release is 14 days old, and exits 1" {
  TODAY=2026-11-26 run "$CHECK" 1.5.4 2026-11-12T00:00:00Z v1.104.7 2026-11-12T22:56:51Z
  [ "$status" -eq 1 ]
  grep -qF '| RustDesk | 1.5.3 | 1.5.4 (2026-11-12) | **Bump due**: released 14 days ago |' <<< "$output"
  grep -qF '| Tailscale | 1.104.4 | 1.104.7 (2026-11-12) | **Bump due**: released 14 days ago |' <<< "$output"
  grep -q '^To bump a pin, change its version and the SHA-256 values' <<< "$output"
}

@test "counts days across a leap day and a year end" {
  TODAY=2024-03-13 run "$CHECK" 1.5.4 2024-02-28T00:00:00Z 1.104.4 2024-01-01T00:00:00Z
  [ "$status" -eq 1 ]
  grep -qF 'released 14 days ago' <<< "$output"
  TODAY=2024-03-13 run "$CHECK" 1.5.4 2024-02-29T00:00:00Z 1.104.4 2024-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  grep -qF 'released 13 days ago' <<< "$output"
  TODAY=2027-01-05 run "$CHECK" 1.5.4 2026-12-22T00:00:00Z 1.104.4 2024-01-01T00:00:00Z
  [ "$status" -eq 1 ]
  grep -qF 'released 14 days ago' <<< "$output"
}

@test "compares versions by number, not as text" {
  pins 1.9.9 1.104.9
  TODAY=2026-11-24 run "$CHECK" 1.10.0 2026-01-01T00:00:00Z v1.104.10 2026-01-01T00:00:00Z
  [ "$status" -eq 1 ]
  grep -qF '| RustDesk | 1.9.9 | 1.10.0 (2026-01-01) | **Bump due**' <<< "$output"
  grep -qF '| Tailscale | 1.104.9 | 1.104.10 (2026-01-01) | **Bump due**' <<< "$output"
}

@test "treats a latest release older than the pin as up to date" {
  pins 1.5.3 1.105.0
  TODAY=2026-11-24 run "$CHECK" 1.4.9 2026-01-01T00:00:00Z v1.104.7 2026-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Up to date |$' <<< "$output")" -eq 2 ]
}

@test "fails when the Mac and Windows pins disagree" {
  pins 1.5.3 1.104.4 1.5.2
  run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
  [ "$status" -eq 2 ]
  grep -qF 'RustDesk pins disagree: Mac 1.5.3, Windows 1.5.2' <<< "$output"
  pins 1.5.3 1.104.4 1.5.3 1.104.5
  run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
  [ "$status" -eq 2 ]
  grep -qF 'Tailscale pins disagree: Mac 1.104.4, Windows 1.104.5' <<< "$output"
}

@test "fails on a pin it can't find, finds twice, or can't read as a version" {
  printf "TD_TAILSCALE_VERSION='1.104.4'\n" > "$TMP/scripts/mac/tailnet-desk.sh"
  run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
  [ "$status" -eq 2 ]
  grep -qF 'expected one TD_RUSTDESK_VERSION pin in scripts/mac/tailnet-desk.sh' <<< "$output"
  pins 1.5.3 1.104.4
  printf "TD_RUSTDESK_VERSION='1.5.4'\n" >> "$TMP/scripts/mac/tailnet-desk.sh"
  run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
  [ "$status" -eq 2 ]
  pins 1.5 1.104.4
  run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
  [ "$status" -eq 2 ]
  grep -qF "not a release version: '1.5'" <<< "$output"
}

@test "refuses a tag, publish time or TODAY that isn't in the expected form" {
  for tag in '1.5.3; rm -rf /' 'nightly' '1.5.3-beta' '1.5' '| x |'; do
    run "$CHECK" "$tag" 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
    [ "$status" -eq 2 ]
    grep -qF 'not a release version' <<< "$output"
  done
  for published in '2026-11-09' 'yesterday' '2026-13-09T09:43:52Z' '2026-11-00T09:43:52Z'; do
    run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 "$published"
    [ "$status" -eq 2 ]
  done
  TODAY=24/11/2026 run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4 2026-10-28T10:00:00Z
  [ "$status" -eq 2 ]
  grep -qF "TODAY isn't YYYY-MM-DD" <<< "$output"
}

@test "needs exactly four arguments" {
  run "$CHECK" 1.5.3 2026-11-09T09:43:52Z v1.104.4
  [ "$status" -eq 2 ]
  grep -qF 'needs 4 arguments' <<< "$output"
}

@test "reads the real scripts' pins, which agree" {
  mac=$(sed -n -E "s/^TD_RUSTDESK_VERSION='(.*)'/\1/p" "$BATS_TEST_DIRNAME/../../scripts/mac/tailnet-desk.sh")
  ts=$(sed -n -E "s/^TD_TAILSCALE_VERSION='(.*)'/\1/p" "$BATS_TEST_DIRNAME/../../scripts/mac/tailnet-desk.sh")
  TODAY=2026-11-24 run "$REAL" "$mac" 2026-01-01T00:00:00Z "v$ts" 2026-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Up to date |$' <<< "$output")" -eq 2 ]
}
