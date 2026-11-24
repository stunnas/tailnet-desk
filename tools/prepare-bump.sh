#!/usr/bin/env bash
# Downloads the installers for each due bump that tools/check-versions.sh listed, hashes them, and prints the new pin
# values as KEY=VALUE lines for the version-watch workflow. It runs in that workflow's read-only job: it changes no
# file in the repo, and the job that opens the PR checks every value again before using it.
#
# The sources and file names are the install scripts' own: Tailscale's package server (TD_TAILSCALE_PKG_BASE) and
# RustDesk's GitHub repo (TD_RUSTDESK_REPO) are read from scripts/mac/tailnet-desk.sh, and the file names follow the
# patterns both install scripts use (tests/tools/prepare-bump.bats checks they match). Each download is checked
# against the hash its own source publishes, and refused on any difference:
#   Tailscale  the .sha256 file next to each installer on Tailscale's package server. It comes from the same server, so
#              it shows the download arrived intact, not who built it.
#   RustDesk   the SHA-256 digest GitHub shows for each asset of RustDesk's release. An asset uploaded or replaced less
#              than two weeks ago is refused, so a file swapped on an old release can't pass for an old one.
# Signatures can't be checked on the Linux runner. The install scripts check them on every install: Authenticode on
# Windows; on the Mac, Apple's signing team for both apps, and Apple's notarization for Tailscale's installer.
#
# Usage: tools/prepare-bump.sh <targets-file> <download-folder>
#   The targets file is check-versions.sh's TARGETS_FILE. Prints, for each due app (rustdesk, tailscale):
#   <app>_version, <app>_date, <app>_covered, then the hashes: tailscale_msi_sha256 and tailscale_pkg_sha256;
#   rustdesk_exe_sha256, rustdesk_dmg_arm64_sha256 and rustdesk_dmg_x86_64_sha256. CUTOFF (YYYY-MM-DD, default 14
#   days before today in UTC, and never later) is the latest upload date a RustDesk asset may have; tests set it to a
#   fixed past date. Exit 0, or 2 when anything is off.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
mac="$root/scripts/mac/tailnet-desk.sh"

die() { echo "prepare-bump: $*" >&2; exit 2; }
[ "$#" -eq 2 ] || die 'needs 2 arguments: the targets file and a download folder (see the header)'
targets=$1 dir=$2
[ -f "$targets" ] || die "no such file: $targets"

# The single-quoted value of setting $1 in the Mac library.
setting() { sed -n -E "s/^$1='([^']*)'.*/\1/p" "$mac"; }
ts_base=$(setting TD_TAILSCALE_PKG_BASE)
rd_repo=$(setting TD_RUSTDESK_REPO)
[[ $ts_base =~ ^https://[a-z0-9.-]+(/[A-Za-z0-9._-]+)*$ ]] || die "TD_TAILSCALE_PKG_BASE isn't an https address: $ts_base"
[[ $rd_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "TD_RUSTDESK_REPO isn't owner/repo: $rd_repo"

# The same two weeks as MIN_AGE_DAYS in tools/check-versions.sh; change both together.
two_weeks_back=$(date -u -d '14 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-14d +%Y-%m-%d)
cutoff=${CUTOFF:-$two_weeks_back}
[[ $cutoff =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "CUTOFF isn't YYYY-MM-DD: $cutoff"
[[ ! $cutoff > $two_weeks_back ]] || die "CUTOFF can't be later than two weeks back ($two_weeks_back)"
mkdir -p "$dir"

ver='[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}'
day='[0-9]{4}-[0-9]{2}-[0-9]{2}'
is_version() { [[ $1 =~ ^$ver$ ]]; }
is_date() { [[ $1 =~ ^$day$ ]]; }
is_covered() { [[ $1 =~ ^$ver:$day(,$ver:$day)*$ ]]; }
is_sha() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Downloads URL $1 into the download folder as $2, over https only, redirects included.
fetch() { curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$dir/$2" "$1" < /dev/null || die "couldn't download $2"; }

# The file names both install scripts download for version $1, as "key name" lines.
tailscale_files() { printf '%s\n' "msi tailscale-setup-$1-amd64.msi" "pkg Tailscale-$1-macos.pkg"; }
rustdesk_files() {
  printf '%s\n' "exe rustdesk-$1-x86_64.exe" "dmg_arm64 rustdesk-$1-aarch64.dmg" "dmg_x86_64 rustdesk-$1-x86_64.dmg"
}

# Tailscale version $1: downloads both installers and checks each against the server's .sha256 file.
tailscale() {
  local v=$1 key name published actual
  while read -r key name; do
    fetch "$ts_base/$name" "$name"
    fetch "$ts_base/$name.sha256" "$name.sha256"
    published=$(tr -d ' \t\r\n' < "$dir/$name.sha256" | cut -c1-64)
    is_sha "$published" || die "$name.sha256 isn't a SHA-256"
    actual=$(sha_of "$dir/$name")
    [ "$actual" = "$published" ] || die "$name doesn't match the SHA-256 Tailscale's server publishes"
    echo "tailscale_${key}_sha256=$actual"
  done < <(tailscale_files "$v")
}

# RustDesk version $1: downloads the Windows installer and both Mac disk images and checks each against GitHub's
# digest, after checking each was uploaded on or before the cutoff.
rustdesk() {
  local v=$1 assets key name digest uploaded actual
  assets=$(gh api "repos/$rd_repo/releases/tags/$v" \
    --jq '.assets[] | .name + " " + (.digest // "-") + " " + .updated_at' < /dev/null) ||
    die "couldn't read RustDesk $v's release"
  while read -r key name; do
    digest=$(awk -v n="$name" '$1 == n { print $2 }' <<< "$assets")
    uploaded=$(awk -v n="$name" '$1 == n { print substr($3, 1, 10) }' <<< "$assets")
    digest=${digest#sha256:}
    is_sha "$digest" || die "GitHub shows no SHA-256 digest for $name"
    is_date "$uploaded" || die "GitHub shows no upload date for $name"
    [[ ! $uploaded > $cutoff ]] || die "$name was uploaded on $uploaded, less than two weeks ago"
    fetch "https://github.com/$rd_repo/releases/download/$v/$name" "$name"
    actual=$(sha_of "$dir/$name")
    [ "$actual" = "$digest" ] || die "$name doesn't match the SHA-256 digest GitHub shows"
    echo "rustdesk_${key}_sha256=$actual"
  done < <(rustdesk_files "$v")
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
