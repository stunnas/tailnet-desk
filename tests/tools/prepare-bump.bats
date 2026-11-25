#!/usr/bin/env bats
# Tests for tools/prepare-bump.sh, with stand-ins for curl and gh, so nothing is downloaded. Run: bats tests/tools

ROOT="$BATS_TEST_DIRNAME/../.."
SCRIPT="$ROOT/tools/prepare-bump.sh"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin" "$TMP/dl"
  # curl: "downloads" a file whose content is "content of <name>"; for <name>.sha256 it writes that content's SHA-256
  # and the name, as Tailscale's server does, or a wrong hash for $BAD_TS, or text for $JUNK_TS. $MISSING fails. It
  # logs each URL.
  cat > "$TMP/bin/curl" << 'EOF'
#!/bin/bash
out='' url=''
while [ "$#" -gt 0 ]; do case $1 in -o|--proto|--proto-redir|--retry) [ "$1" = -o ] && out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
echo "$url" >> "$LOG"
name=${url##*/}
[ -z "${MISSING-}" ] || [ "$name" != "$MISSING" ] || exit 22
case $name in
  *.sha256) base=${name%.sha256}
    if [ "$base" = "${BAD_TS-}" ]; then printf '%064d  %s\n' 0 "$base" > "$out"
    elif [ "$base" = "${JUNK_TS-}" ]; then printf 'not a hash\n' > "$out"
    else printf '%s  %s\n' "$(printf 'content of %s' "$base" | shasum -a 256 | cut -d' ' -f1)" "$base" > "$out"; fi ;;
  *) printf 'content of %s' "$name" > "$out" ;;
esac
EOF
  # gh: RustDesk's release lists each asset with the SHA-256 of its content and an upload time of $UPLOADED, except
  # $NO_DIGEST (no digest), $BAD_RD (a wrong one) and $RECENT (uploaded on 2026-11-20). $GH_FAIL makes it fail.
  cat > "$TMP/bin/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "$LOG"
[ -z "${GH_FAIL-}" ] || exit 1
v=${2##*/}
for name in "rustdesk-$v-x86_64.exe" "rustdesk-$v-aarch64.dmg" "rustdesk-$v-x86_64.dmg" "rustdesk-$v-x86_64.msi"; do
  when=${UPLOADED:-2026-11-01T10:00:00Z}; [ "$name" != "${RECENT-}" ] || when=2026-11-20T10:00:00Z
  if [ "$name" = "${NO_DIGEST-}" ]; then echo "$name - $when"
  elif [ "$name" = "${BAD_RD-}" ]; then printf '%s sha256:%064d %s\n' "$name" 0 "$when"
  else echo "$name sha256:$(printf 'content of %s' "$name" | shasum -a 256 | cut -d' ' -f1) $when"; fi
done
EOF
  chmod +x "$TMP/bin/curl" "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" LOG="$TMP/log" CUTOFF=2026-11-10
  : > "$LOG"
}

teardown() {
  rm -rf "$TMP"
}

sha() { printf 'content of %s' "$1" | shasum -a 256 | cut -d' ' -f1; }

prepare() {
  printf '%s\n' "$@" > "$TMP/targets.txt"
  run "$SCRIPT" "$TMP/targets.txt" "$TMP/dl"
}

@test "gives Tailscale's version, date, list and both installers' hashes, from the install scripts' server" {
  prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = tailscale_version=1.104.5 ]
  [ "${lines[1]}" = tailscale_date=2026-11-03 ]
  [ "${lines[2]}" = tailscale_covered=1.104.5:2026-11-03 ]
  [ "${lines[3]}" = "tailscale_msi_sha256=$(sha tailscale-setup-1.104.5-amd64.msi)" ]
  [ "${lines[4]}" = "tailscale_pkg_sha256=$(sha Tailscale-1.104.5-macos.pkg)" ]
  base=$(sed -n "s/^TD_TAILSCALE_PKG_BASE='\(.*\)'.*/\1/p" "$ROOT/scripts/mac/tailnet-desk.sh")
  grep -qx "$base/tailscale-setup-1.104.5-amd64.msi" "$LOG"
  grep -qx "$base/Tailscale-1.104.5-macos.pkg.sha256" "$LOG"
}

@test "gives RustDesk's hashes for the Windows installer and both Mac disk images, from the install scripts' repo" {
  prepare 'RustDesk 1.5.5 2026-11-01 1.5.5:2026-11-01,1.5.4:2026-10-20'
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = rustdesk_covered=1.5.5:2026-11-01,1.5.4:2026-10-20 ]
  [ "${lines[3]}" = "rustdesk_exe_sha256=$(sha rustdesk-1.5.5-x86_64.exe)" ]
  [ "${lines[4]}" = "rustdesk_dmg_arm64_sha256=$(sha rustdesk-1.5.5-aarch64.dmg)" ]
  [ "${lines[5]}" = "rustdesk_dmg_x86_64_sha256=$(sha rustdesk-1.5.5-x86_64.dmg)" ]
  repo=$(sed -n "s/^TD_RUSTDESK_REPO='\([^']*\)'.*/\1/p" "$ROOT/scripts/mac/tailnet-desk.sh")
  grep -qx "gh api repos/$repo/releases/tags/1.5.5 --jq .*" "$LOG"
  grep -qx "https://github.com/$repo/releases/download/1.5.5/rustdesk-1.5.5-aarch64.dmg" "$LOG"
}

@test "hashes the same file names the install scripts download" {
  # The Mac library's own functions, for a made-up version, and the Windows module's name patterns.
  mac_rd=$(/bin/bash -c '. "$1"; TD_RUSTDESK_VERSION=9.8.7; td_rustdesk_asset arm64 | head -1; td_rustdesk_asset x86_64 | head -1' x "$ROOT/scripts/mac/tailnet-desk.sh")
  mac_ts=$(/bin/bash -c '. "$1"; TD_TAILSCALE_VERSION=9.8.7; td_tailscale_pkg_name' x "$ROOT/scripts/mac/tailnet-desk.sh")
  [ "$mac_rd" = $'rustdesk-9.8.7-aarch64.dmg\nrustdesk-9.8.7-x86_64.dmg' ]
  [ "$mac_ts" = Tailscale-9.8.7-macos.pkg ]
  psm1="$ROOT/scripts/windows/tailnet-desk.psm1"
  grep -qF 'RustDeskAsset -NotePropertyValue "rustdesk-$($script:Setting.RustDeskVersion)-x86_64.exe"' "$psm1"
  grep -qF 'TailscaleMsi -NotePropertyValue "tailscale-setup-$($script:Setting.TailscaleVersion)-amd64.msi"' "$psm1"
  prepare 'RustDesk 9.8.7 2026-11-01 9.8.7:2026-11-01' 'Tailscale 9.8.7 2026-11-01 9.8.7:2026-11-01'
  [ "$status" -eq 0 ]
  for name in rustdesk-9.8.7-x86_64.exe rustdesk-9.8.7-aarch64.dmg rustdesk-9.8.7-x86_64.dmg \
    tailscale-setup-9.8.7-amd64.msi Tailscale-9.8.7-macos.pkg; do
    grep -q "/$name\$" "$LOG"
  done
  [ "${#lines[@]}" -eq 11 ]
}

@test "refuses a Tailscale installer that doesn't match its server's .sha256 file, or a file that isn't a hash" {
  BAD_TS=Tailscale-1.104.5-macos.pkg prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 2 ]
  grep -qF "Tailscale-1.104.5-macos.pkg doesn't match the SHA-256 Tailscale's server publishes" <<< "$output"
  JUNK_TS=tailscale-setup-1.104.5-amd64.msi prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 2 ]
  grep -qF "tailscale-setup-1.104.5-amd64.msi.sha256 isn't a SHA-256" <<< "$output"
}

@test "refuses a RustDesk download that doesn't match GitHub's digest, or has none" {
  BAD_RD=rustdesk-1.5.5-x86_64.dmg prepare 'RustDesk 1.5.5 2026-11-01 1.5.5:2026-11-01'
  [ "$status" -eq 2 ]
  grep -qF "rustdesk-1.5.5-x86_64.dmg doesn't match the SHA-256 digest GitHub shows" <<< "$output"
  NO_DIGEST=rustdesk-1.5.5-x86_64.exe prepare 'RustDesk 1.5.5 2026-11-01 1.5.5:2026-11-01'
  [ "$status" -eq 2 ]
  grep -qF 'GitHub shows no SHA-256 digest for rustdesk-1.5.5-x86_64.exe' <<< "$output"
}

@test "refuses a RustDesk asset uploaded after the cutoff, before downloading it" {
  RECENT=rustdesk-1.5.5-aarch64.dmg prepare 'RustDesk 1.5.5 2026-11-01 1.5.5:2026-11-01'
  [ "$status" -eq 2 ]
  grep -qF 'rustdesk-1.5.5-aarch64.dmg was uploaded on 2026-11-20, less than two weeks ago' <<< "$output"
  ! grep -q 'aarch64.dmg$' "$LOG" || false
  UPLOADED=2026-11-10T23:00:00Z prepare 'RustDesk 1.5.5 2026-11-01 1.5.5:2026-11-01'
  [ "$status" -eq 0 ]
}

@test "stops when RustDesk's release can't be read, or a download fails" {
  GH_FAIL=1 prepare 'RustDesk 1.5.5 2026-11-01 1.5.5:2026-11-01'
  [ "$status" -eq 2 ]
  grep -qF "couldn't read RustDesk 1.5.5's release" <<< "$output"
  MISSING=rustdesk-1.5.5-aarch64.dmg prepare 'RustDesk 1.5.5 2026-11-01 1.5.5:2026-11-01'
  [ "$status" -eq 2 ]
  grep -qF "couldn't download rustdesk-1.5.5-aarch64.dmg" <<< "$output"
  MISSING=tailscale-setup-1.104.5-amd64.msi prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 2 ]
  grep -qF "couldn't download tailscale-setup-1.104.5-amd64.msi" <<< "$output"
}

@test "refuses a targets line that isn't in the expected form, and says why, before downloading anything" {
  check_line() {
    : > "$LOG"
    prepare "$1"
    [ "$status" -eq 2 ]
    grep -qF "$2" <<< "$output"
    [ ! -s "$LOG" ]
  }
  check_line 'Tailscale 1.104 2026-11-03 1.104.5:2026-11-03' 'Tailscale: not a version: 1.104'
  check_line 'Tailscale 1.104.5 03-11-2026 1.104.5:2026-11-03' 'Tailscale: not a date: 03-11-2026'
  check_line 'Tailscale 1.104.5 2026-11-03 1.104.5' 'Tailscale: not a list of version:date'
  check_line 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03 extra' 'a targets line has more than four fields'
  check_line 'Other 1.0.0 2026-11-03 1.0.0:2026-11-03' 'unknown app: Other'
}

@test "stops when no bump is listed, or the cutoff isn't a date" {
  prepare ''
  [ "$status" -eq 2 ]
  grep -qF 'no due bumps listed' <<< "$output"
  CUTOFF=soon prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 2 ]
  grep -qF "CUTOFF isn't YYYY-MM-DD" <<< "$output"
  CUTOFF=2999-01-01 prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 2 ]
  grep -qF "CUTOFF can't be later than two weeks back" <<< "$output"
}

@test "prints exactly the keys the workflow's watch job passes on" {
  prepare 'RustDesk 9.8.7 2026-11-01 9.8.7:2026-11-01' 'Tailscale 9.8.7 2026-11-01 9.8.7:2026-11-01'
  [ "$status" -eq 0 ]
  printed=$(printf '%s\n' "${lines[@]}" | cut -d= -f1 | sort)
  passed=$(sed -n -E 's/.*steps\.prepare\.outputs\.([a-z0-9_]+).*/\1/p' "$ROOT/.github/workflows/version-watch.yml" | sort)
  used=$(sed -n -E 's/.*needs\.watch\.outputs\.([a-z0-9_]+).*/\1/p' "$ROOT/.github/workflows/version-watch.yml" | grep -vx due | sort)
  [ "$printed" = "$passed" ]
  [ "$printed" = "$used" ]
}
