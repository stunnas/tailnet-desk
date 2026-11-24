#!/usr/bin/env bash
# Downloads the installers for each due bump that tools/check-versions.sh listed, hashes them, and prints the new pin
# values as KEY=VALUE lines for the version-watch workflow. It runs in that workflow's read-only job: it changes no
# file in the repo, and the job that opens the PR checks every value again before using it.
#
# Each download is checked against the hash its own source publishes, and refused on any difference:
#   Tailscale  the .sha256 file next to each installer on Tailscale's package server (TD_TAILSCALE_PKG_BASE)
#   RustDesk   the SHA-256 digest GitHub shows for each asset of RustDesk's release
# Signatures (Authenticode, Apple's team and notarization) can't be checked on the Linux runner; the install scripts
# check them on every install, and the bump PR says so.
#
# Usage: tools/prepare-bump.sh <targets-file> <download-folder>
#   The targets file is check-versions.sh's TARGETS_FILE. Prints, for each due app (rustdesk, tailscale):
#   <app>_version, <app>_date, <app>_covered, then the hashes: tailscale_msi_sha256 and tailscale_pkg_sha256;
#   rustdesk_exe_sha256, rustdesk_dmg_arm64_sha256 and rustdesk_dmg_x86_64_sha256. Exit 0, or 2 when anything is off.
set -euo pipefail

TS_BASE=${TS_BASE:-https://pkgs.tailscale.com/stable}       # the same server the install scripts download from
RD_REPO=rustdesk/rustdesk

die() { echo "prepare-bump: $*" >&2; exit 2; }
[ "$#" -eq 2 ] || die 'needs 2 arguments: the targets file and a download folder (see the header)'
targets=$1 dir=$2
[ -f "$targets" ] || die "no such file: $targets"
mkdir -p "$dir"

is_version() { [[ $1 =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]]; }
is_date() { [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }
is_covered() { [[ $1 =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}:[0-9]{4}-[0-9]{2}-[0-9]{2}(,[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}:[0-9]{4}-[0-9]{2}-[0-9]{2})*$ ]]; }
is_sha() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Downloads URL $1 into the download folder as $2.
fetch() { curl -fsSL --proto '=https' --retry 3 -o "$dir/$2" "$1" || die "couldn't download $2"; }

# Tailscale version $1: downloads both installers and checks each against the server's .sha256 file.
tailscale() {
  local v=$1 name published actual key
  for pair in "msi tailscale-setup-$v-amd64.msi" "pkg Tailscale-$v-macos.pkg"; do
    key=${pair%% *}; name=${pair#* }
    fetch "$TS_BASE/$name" "$name"
    fetch "$TS_BASE/$name.sha256" "$name.sha256"
    published=$(tr -d ' \t\r\n' < "$dir/$name.sha256" | cut -c1-64)
    is_sha "$published" || die "$name.sha256 isn't a SHA-256"
    actual=$(sha_of "$dir/$name")
    [ "$actual" = "$published" ] || die "$name doesn't match the SHA-256 Tailscale's server publishes"
    echo "tailscale_${key}_sha256=$actual"
  done
}

# RustDesk version $1: downloads the Windows installer and both Mac disk images and checks each against GitHub's digest.
rustdesk() {
  local v=$1 digests name key digest actual
  digests=$(gh api "repos/$RD_REPO/releases/tags/$v" --jq '.assets[] | .name + " " + (.digest // "")') ||
    die "couldn't read RustDesk $v's release"
  for pair in "exe rustdesk-$v-x86_64.exe" "dmg_arm64 rustdesk-$v-aarch64.dmg" "dmg_x86_64 rustdesk-$v-x86_64.dmg"; do
    key=${pair%% *}; name=${pair#* }
    digest=$(awk -v n="$name" '$1 == n { print $2 }' <<< "$digests")
    digest=${digest#sha256:}
    is_sha "$digest" || die "GitHub shows no SHA-256 digest for $name"
    fetch "https://github.com/$RD_REPO/releases/download/$v/$name" "$name"
    actual=$(sha_of "$dir/$name")
    [ "$actual" = "$digest" ] || die "$name doesn't match the SHA-256 digest GitHub shows"
    echo "rustdesk_${key}_sha256=$actual"
  done
}

lines=0
while read -r app version date covered rest; do
  [ -n "${app-}" ] || continue
  [ -z "${rest-}" ] || die 'a targets line has more than four fields'
  is_version "$version" || die "$app: not a version: $version"
  is_date "$date" || die "$app: not a date: $date"
  is_covered "$covered" || die "$app: not a list of version:date"
  case $app in
    Tailscale) echo "tailscale_version=$version"; echo "tailscale_date=$date"; echo "tailscale_covered=$covered"; tailscale "$version" ;;
    RustDesk) echo "rustdesk_version=$version"; echo "rustdesk_date=$date"; echo "rustdesk_covered=$covered"; rustdesk "$version" ;;
    *) die "unknown app: $app" ;;
  esac
  lines=$((lines + 1))
done < "$targets"
[ "$lines" -gt 0 ] || die 'no due bumps listed'
