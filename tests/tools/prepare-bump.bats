#!/usr/bin/env bats
# Tests for tools/prepare-bump.sh, with stand-ins for curl and gh, so nothing is downloaded. Run: bats tests/tools

SCRIPT="$BATS_TEST_DIRNAME/../../tools/prepare-bump.sh"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin" "$TMP/dl"
  # curl: "downloads" a file whose content is "content of <name>"; for <name>.sha256 it writes that content's SHA-256,
  # or a wrong one for the name in $BAD_TS. It logs each URL.
  cat > "$TMP/bin/curl" << 'EOF'
#!/bin/bash
out='' url=''
while [ "$#" -gt 0 ]; do case $1 in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
echo "$url" >> "$LOG"
name=${url##*/}
[ -z "${MISSING-}" ] || [ "$name" != "$MISSING" ] || exit 22
case $name in
  *.sha256) base=${name%.sha256}
    if [ "$base" = "${BAD_TS-}" ]; then printf '%064d  %s\n' 0 "$base" > "$out"
    else printf 'content of %s' "$base" | shasum -a 256 | cut -d' ' -f1 > "$out"; fi ;;
  *) printf 'content of %s' "$name" > "$out" ;;
esac
EOF
  # gh: RustDesk's release lists each asset with the SHA-256 of its content, except $NO_DIGEST (no digest) and
  # $BAD_RD (a wrong one).
  cat > "$TMP/bin/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "$LOG"
v=${2##*/}
for name in "rustdesk-$v-x86_64.exe" "rustdesk-$v-aarch64.dmg" "rustdesk-$v-x86_64.dmg" "rustdesk-$v-x86_64.msi"; do
  if [ "$name" = "${NO_DIGEST-}" ]; then echo "$name "
  elif [ "$name" = "${BAD_RD-}" ]; then printf '%s sha256:%064d\n' "$name" 0
  else echo "$name sha256:$(printf 'content of %s' "$name" | shasum -a 256 | cut -d' ' -f1)"; fi
done
EOF
  chmod +x "$TMP/bin/curl" "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" LOG="$TMP/log"
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

@test "gives Tailscale's version, date, list and both installers' hashes, from its package server" {
  prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = tailscale_version=1.104.5 ]
  [ "${lines[1]}" = tailscale_date=2026-11-03 ]
  [ "${lines[2]}" = tailscale_covered=1.104.5:2026-11-03 ]
  [ "${lines[3]}" = "tailscale_msi_sha256=$(sha tailscale-setup-1.104.5-amd64.msi)" ]
  [ "${lines[4]}" = "tailscale_pkg_sha256=$(sha Tailscale-1.104.5-macos.pkg)" ]
  grep -qx 'https://pkgs.tailscale.com/stable/tailscale-setup-1.104.5-amd64.msi' "$LOG"
  grep -qx 'https://pkgs.tailscale.com/stable/Tailscale-1.104.5-macos.pkg.sha256' "$LOG"
}

@test "gives RustDesk's hashes for the Windows installer and both Mac disk images, from its GitHub release" {
  prepare 'RustDesk 1.5.5 2026-11-20 1.5.5:2026-11-20,1.5.4:2026-11-12'
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = rustdesk_covered=1.5.5:2026-11-20,1.5.4:2026-11-12 ]
  [ "${lines[3]}" = "rustdesk_exe_sha256=$(sha rustdesk-1.5.5-x86_64.exe)" ]
  [ "${lines[4]}" = "rustdesk_dmg_arm64_sha256=$(sha rustdesk-1.5.5-aarch64.dmg)" ]
  [ "${lines[5]}" = "rustdesk_dmg_x86_64_sha256=$(sha rustdesk-1.5.5-x86_64.dmg)" ]
  grep -qx 'gh api repos/rustdesk/rustdesk/releases/tags/1.5.5 --jq .*' "$LOG"
  grep -qx 'https://github.com/rustdesk/rustdesk/releases/download/1.5.5/rustdesk-1.5.5-aarch64.dmg' "$LOG"
}

@test "handles both apps in one run" {
  prepare 'RustDesk 1.5.5 2026-11-20 1.5.5:2026-11-20' 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
}

@test "refuses a Tailscale installer that doesn't match its server's .sha256 file" {
  BAD_TS=Tailscale-1.104.5-macos.pkg prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 2 ]
  grep -qF "Tailscale-1.104.5-macos.pkg doesn't match the SHA-256 Tailscale's server publishes" <<< "$output"
}

@test "refuses a RustDesk download that doesn't match GitHub's digest, or has none" {
  BAD_RD=rustdesk-1.5.5-x86_64.dmg prepare 'RustDesk 1.5.5 2026-11-20 1.5.5:2026-11-20'
  [ "$status" -eq 2 ]
  grep -qF "rustdesk-1.5.5-x86_64.dmg doesn't match the SHA-256 digest GitHub shows" <<< "$output"
  NO_DIGEST=rustdesk-1.5.5-x86_64.exe prepare 'RustDesk 1.5.5 2026-11-20 1.5.5:2026-11-20'
  [ "$status" -eq 2 ]
  grep -qF 'GitHub shows no SHA-256 digest for rustdesk-1.5.5-x86_64.exe' <<< "$output"
}

@test "stops when a download fails" {
  MISSING=tailscale-setup-1.104.5-amd64.msi prepare 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03'
  [ "$status" -eq 2 ]
  grep -qF "couldn't download tailscale-setup-1.104.5-amd64.msi" <<< "$output"
}

@test "refuses a targets line that isn't in the expected form, before downloading anything" {
  for line in 'Tailscale 1.104 2026-11-03 1.104.5:2026-11-03' 'Tailscale 1.104.5 03-11-2026 1.104.5:2026-11-03' \
    'Tailscale 1.104.5 2026-11-03 1.104.5' 'Tailscale 1.104.5 2026-11-03 1.104.5:2026-11-03 extra' \
    'Other 1.0.0 2026-11-03 1.0.0:2026-11-03'; do
    : > "$LOG"
    prepare "$line"
    [ "$status" -eq 2 ]
    [ ! -s "$LOG" ]
  done
}

@test "stops when no bump is listed" {
  prepare ''
  [ "$status" -eq 2 ]
  grep -qF 'no due bumps listed' <<< "$output"
}
