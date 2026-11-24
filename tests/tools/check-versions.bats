#!/usr/bin/env bats
# Tests for tools/check-versions.sh. Run: bats tests/tools
# Each test runs a copy of the script in a made-up repo whose pins it writes, with made-up release lists, so the real
# pins and releases can change freely. Every run sets TODAY, so no result depends on the clock.

REAL="$BATS_TEST_DIRNAME/../../tools/check-versions.sh"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/tools" "$TMP/scripts/mac" "$TMP/scripts/windows"
  cp "$REAL" "$TMP/tools/check-versions.sh"
  CHECK="$TMP/tools/check-versions.sh"
  RD="$TMP/rustdesk.txt"; TS="$TMP/tailscale.txt"
  pins 1.5.3 1.104.4
  releases "$RD" '1.5.3 2026-11-09T09:43:52Z' '1.5.2 2026-09-01T00:00:00Z'
  releases "$TS" 'v1.104.4 2026-10-28T10:00:00Z'
  export TODAY=2026-11-24
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

# Writes the release lines after $1 into file $1, newest first as GitHub lists them.
releases() {
  local file=$1; shift
  printf '%s\n' "$@" > "$file"
}

@test "reports both up to date, and exits 0" {
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'Pinned versions compared with the releases on 2026-11-24.' ]
  grep -qF '| RustDesk | 1.5.3 | 1.5.3 (2026-11-09) | Up to date |' <<< "$output"
  grep -qF '| Tailscale | 1.104.4 | 1.104.4 (2026-10-28) | Up to date |' <<< "$output"
  ! grep -q 'To bump a pin' <<< "$output" || false
}

@test "waits while every release newer than the pin is younger than 14 days, and exits 0" {
  releases "$TS" 'v1.104.7 2026-11-12T22:56:51Z' 'v1.104.4 2026-10-28T10:00:00Z'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 0 ]
  grep -qF '| Tailscale | 1.104.4 | 1.104.7 (2026-11-12) | Newer, but none newer than the pin is 14 days old yet (the latest is 12 days old) |' <<< "$output"
  ! grep -q 'To bump a pin' <<< "$output" || false
}

@test "says a bump is due once a newer release is 14 days old, and exits 1" {
  releases "$TS" 'v1.104.7 2026-11-10T22:56:51Z' 'v1.104.4 2026-10-28T10:00:00Z'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 1 ]
  grep -qF '| Tailscale | 1.104.4 | 1.104.7 (2026-11-10) | **Bump due**: to 1.104.7, released 14 days ago |' <<< "$output"
  grep -qF '| RustDesk | 1.5.3 | 1.5.3 (2026-11-09) | Up to date |' <<< "$output"
  grep -q '^To bump a pin, change in both' <<< "$output"
  grep -qF 'the release date in the comment above it' <<< "$output"
  grep -qF 'both disk images' <<< "$output"
}

@test "bumps to the newest release that is 14 days old, even when a newer one is younger" {
  releases "$TS" 'v1.104.7 2026-11-21T00:00:00Z' 'v1.104.6 2026-11-08T00:00:00Z' 'v1.104.5 2026-11-03T00:00:00Z' \
    'v1.104.4 2026-10-28T10:00:00Z'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 1 ]
  grep -qF '| Tailscale | 1.104.4 | 1.104.7 (2026-11-21) | **Bump due**: to 1.104.6, released 16 days ago |' <<< "$output"
  releases "$TS" 'v1.104.5 2026-11-03T00:00:00Z' 'v1.104.6 2026-11-08T00:00:00Z' 'v1.104.7 2026-11-21T00:00:00Z'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 1 ]
  grep -qF '**Bump due**: to 1.104.6, released 16 days ago' <<< "$output"
}

@test "picks the newest version, whatever order the releases are listed in" {
  releases "$RD" '1.5.2 2026-01-01T00:00:00Z' '1.10.0 2026-01-01T00:00:00Z' '1.9.9 2026-01-01T00:00:00Z'
  releases "$TS" 'v1.104.10 2026-01-01T00:00:00Z' 'v1.104.9 2026-01-01T00:00:00Z'
  pins 1.9.9 1.104.9
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 1 ]
  grep -qF '| RustDesk | 1.9.9 | 1.10.0 (2026-01-01) | **Bump due**: to 1.10.0' <<< "$output"
  grep -qF '| Tailscale | 1.104.9 | 1.104.10 (2026-01-01) | **Bump due**: to 1.104.10' <<< "$output"
}

@test "treats releases all older than the pin as up to date" {
  pins 1.5.3 1.105.0
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Up to date |$' <<< "$output")" -eq 2 ]
}

@test "counts days across a leap day and a year end" {
  releases "$TS" 'v1.104.4 2023-12-31T00:00:00Z'
  releases "$RD" '1.5.4 2024-02-28T00:00:00Z'
  TODAY=2024-03-13 run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 1 ]
  grep -qF 'to 1.5.4, released 14 days ago' <<< "$output"
  releases "$RD" '1.5.4 2024-02-29T00:00:00Z'
  TODAY=2024-03-13 run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 0 ]
  grep -qF 'the latest is 13 days old' <<< "$output"
  releases "$RD" '1.5.4 2026-12-22T00:00:00Z'
  TODAY=2027-01-05 run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 1 ]
  grep -qF 'to 1.5.4, released 14 days ago' <<< "$output"
}

@test "leaves out tags not shaped like a version, and says how many" {
  releases "$RD" 'nightly 2026-11-20T00:00:00Z' '' '1.5.3 2026-11-09T09:43:52Z' '1.2.3-2 2023-09-01T00:00:00Z'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 0 ]
  grep -qF '| RustDesk | 1.5.3 | 1.5.3 (2026-11-09) | Up to date. Left out 2 tag(s) not shaped like a version |' <<< "$output"
  releases "$RD" 'nightly 2026-11-20T00:00:00Z' 'v1.x 2026-11-09T09:43:52Z'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'RustDesk: no release with a version tag listed' <<< "$output"
}

@test "reads a last line with no newline, and parts with leading zeros as numbers" {
  printf '1.05.10 2026-01-01T00:00:00Z' > "$RD"
  pins 1.5.9 1.104.4
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 1 ]
  grep -qF '| RustDesk | 1.5.9 | 1.05.10 (2026-01-01) | **Bump due**: to 1.05.10' <<< "$output"
}

@test "refuses a release list that is empty, missing or has extra words" {
  : > "$RD"
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'RustDesk: no release with a version tag listed' <<< "$output"
  run "$CHECK" "$TMP/nothing.txt" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'RustDesk: no such file' <<< "$output"
  releases "$RD" '1.5.3 2026-11-09T09:43:52Z'
  releases "$TS" 'v1.104.4 2026-10-28T10:00:00Z extra'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'Tailscale: a release line has more than a tag and a time' <<< "$output"
}

@test "refuses a publish time that isn't one, and says why" {
  for time in '2026-11-09' 'yesterday' '' '2026-11-09T09:43:52Z::warning::x'; do
    releases "$TS" "v1.104.4 $time"
    run "$CHECK" "$RD" "$TS"
    [ "$status" -eq 2 ]
    grep -qF 'Tailscale 1.104.4: not a publish time' <<< "$output"
    ! grep -qF '::warning' <<< "$output" || false
  done
  for time in '2026-13-09T09:43:52Z' '2026-11-00T09:43:52Z' '2026-02-29T00:00:00Z' '2026-04-31T00:00:00Z'; do
    releases "$TS" "v1.104.4 $time"
    run "$CHECK" "$RD" "$TS"
    [ "$status" -eq 2 ]
    grep -qF 'not a date' <<< "$output"
  done
}

@test "refuses a release published after TODAY" {
  releases "$TS" 'v1.104.5 2026-11-25T00:00:00Z'
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'Tailscale 1.104.5: published after TODAY (2026-11-24)' <<< "$output"
}

@test "refuses a TODAY that isn't YYYY-MM-DD" {
  TODAY=24/11/2026 run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF "TODAY isn't YYYY-MM-DD" <<< "$output"
}

@test "fails when the Mac and Windows pins disagree" {
  pins 1.5.3 1.104.4 1.5.2
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'RustDesk pins disagree: Mac 1.5.3, Windows 1.5.2' <<< "$output"
  pins 1.5.3 1.104.4 1.5.3 1.104.5
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'Tailscale pins disagree: Mac 1.104.4, Windows 1.104.5' <<< "$output"
}

@test "fails on a pin it can't find, finds twice, or can't read as a version" {
  printf "TD_TAILSCALE_VERSION='1.104.4'\n" > "$TMP/scripts/mac/tailnet-desk.sh"
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'expected one TD_RUSTDESK_VERSION pin in scripts/mac/tailnet-desk.sh' <<< "$output"
  pins 1.5.3 1.104.4
  printf "TD_RUSTDESK_VERSION='1.5.4'\n" >> "$TMP/scripts/mac/tailnet-desk.sh"
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF 'expected one TD_RUSTDESK_VERSION pin in scripts/mac/tailnet-desk.sh' <<< "$output"
  pins 1.5 1.104.4
  run "$CHECK" "$RD" "$TS"
  [ "$status" -eq 2 ]
  grep -qF "not a release version: '1.5'" <<< "$output"
}

@test "needs exactly two arguments" {
  run "$CHECK" "$RD"
  [ "$status" -eq 2 ]
  grep -qF 'needs 2 arguments' <<< "$output"
}

@test "reads the real scripts' pins, which agree" {
  mac="$BATS_TEST_DIRNAME/../../scripts/mac/tailnet-desk.sh"
  releases "$RD" "$(sed -n -E "s/^TD_RUSTDESK_VERSION='(.*)'/\1/p" "$mac") 2026-01-01T00:00:00Z"
  releases "$TS" "v$(sed -n -E "s/^TD_TAILSCALE_VERSION='(.*)'/\1/p" "$mac") 2026-01-01T00:00:00Z"
  run "$REAL" "$RD" "$TS"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Up to date |$' <<< "$output")" -eq 2 ]
}
