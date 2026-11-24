#!/usr/bin/env bash
# Compares the RustDesk and Tailscale versions the install scripts pin with their releases, and prints a Markdown
# report. A bump is due when a release newer than the pin is at least MIN_AGE_DAYS old; the report names the newest
# such release, which is the one to bump to. It never changes a file: the version-watch workflow opens the bump PR,
# with hashes from tools/prepare-bump.sh, and trying the new version on a real machine stays by hand. The workflow looks
# the releases up and passes them in, so this script itself never uses the network.
#
# Usage: tools/check-versions.sh <rustdesk-releases> <tailscale-releases>
#   Each is a file with one release per line: its tag (1.5.3 or v1.104.7), a space, and its GitHub publish time
#   (2026-11-09T09:43:52Z). A tag not shaped like a version (such as 1.2.3-2) is left out, and the report says how
#   many were. TODAY (YYYY-MM-DD, default today in UTC) sets the date the releases' ages are counted to.
#   TARGETS_FILE, when set, also gets one line per due bump for the version-watch workflow: the app, the version to
#   bump to, its release date, and every release newer than the pin up to it as version:date, comma-separated, highest
#   version first (RustDesk 1.5.5 2026-11-20 1.5.5:2026-11-20,1.5.4:2026-11-12). Each value has passed the checks below.
# Exit: 0 when no pin is due a bump, 1 when one is (the report says which and to what), 2 on bad input or when the
# Mac and Windows pins disagree.
set -euo pipefail

[ -z "${TARGETS_FILE-}" ] || : > "$TARGETS_FILE"
MIN_AGE_DAYS=14 # the repo bumps pins only to releases at least two weeks old

root=$(cd "$(dirname "$0")/.." && pwd)
mac="$root/scripts/mac/tailnet-desk.sh"
win="$root/scripts/windows/tailnet-desk.psm1"

die() { echo "check-versions: $*" >&2; exit 2; }

# A refused value, cut to plain characters so text from outside can't pass for log commands.
shown() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c 1-40; }

[ "$#" -eq 2 ] || die 'needs 2 arguments: the RustDesk and Tailscale release files (see the header)'

# 0 when tag $1 is a version: 1.2.3, with an optional leading v.
is_version() { [[ ${1#v} =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]]; }

# The version in tag $1; anything not shaped like one is refused, since it comes from outside.
version_of() {
  is_version "$1" || die "not a release version: '$(shown "$1")'"
  echo "${1#v}"
}

# Days since 1970-01-01 for a real YYYY-MM-DD date, in plain arithmetic so it works the same with GNU and BSD date.
days_of() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "not a date: '$(shown "$1")'"
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) last era yoe doy doe
  case $m in
    1|3|5|7|8|10|12) last=31 ;;
    4|6|9|11) last=30 ;;
    2) if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then last=29; else last=28; fi ;;
    *) die "not a date: '$1'" ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$last" ] || die "not a date: '$1'"
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400)); yoe=$((y - era * 400))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $((era * 146097 + doe - 719468))
}

# 0 when version $1 is newer than $2.
newer() {
  local IFS=. a b i
  read -r -a a <<< "$1"; read -r -a b <<< "$2"
  for i in 0 1 2; do
    [ "$((10#${a[i]}))" -gt "$((10#${b[i]}))" ] && return 0
    [ "$((10#${a[i]}))" -lt "$((10#${b[i]}))" ] && return 1
  done
  return 1
}

# The single-quoted value of a pin line such as TD_RUSTDESK_VERSION='1.5.3' or RustDeskVersion = '1.5.3'.
pin() {
  local file=$1 pattern=$2 value
  value=$(sed -n -E "s/^[[:space:]]*${pattern}[[:space:]]*=[[:space:]]*'([^']*)'.*/\\1/p" "$file")
  [ "$(printf '%s\n' "$value" | grep -c .)" -eq 1 ] || die "expected one $pattern pin in ${file#"$root"/}"
  version_of "$value" > /dev/null
  echo "$value"
}

today=${TODAY:-$(date -u +%Y-%m-%d)}
[[ $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "TODAY isn't YYYY-MM-DD: '$(shown "$today")'"
today_days=$(days_of "$today")

rustdesk_mac=$(pin "$mac" TD_RUSTDESK_VERSION); rustdesk_win=$(pin "$win" RustDeskVersion)
tailscale_mac=$(pin "$mac" TD_TAILSCALE_VERSION); tailscale_win=$(pin "$win" TailscaleVersion)
[ "$rustdesk_mac" = "$rustdesk_win" ] || die "RustDesk pins disagree: Mac $rustdesk_mac, Windows $rustdesk_win"
[ "$tailscale_mac" = "$tailscale_win" ] || die "Tailscale pins disagree: Mac $tailscale_mac, Windows $tailscale_win"

due=0
rows=()
# Adds one report row for app $1 pinned at $2, whose releases are listed in file $3.
check() {
  local app=$1 pinned=$2 file=$3 tag time rest version date date_days age count=0 skipped=0
  local latest='' latest_date='' latest_age=0 target='' target_age=0 target_date='' state covered='' i
  local versions=() dates=()
  [ -f "$file" ] || die "$app: no such file: $file"
  while IFS=' ' read -r tag time rest || [ -n "$tag" ]; do
    [ -n "$tag" ] || continue
    [ -z "$rest" ] || die "$app: a release line has more than a tag and a time"
    if ! is_version "$tag"; then skipped=$((skipped + 1)); continue; fi
    version=${tag#v}
    [[ ${time-} =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
      die "$app $version: not a publish time: '$(shown "${time-}")'"
    date=${BASH_REMATCH[1]}
    date_days=$(days_of "$date")
    age=$((today_days - date_days))
    [ "$age" -ge 0 ] || die "$app $version: published after TODAY ($today)"
    count=$((count + 1))
    versions+=("$version"); dates+=("$date")
    if [ -z "$latest" ] || newer "$version" "$latest"; then latest=$version; latest_date=$date; latest_age=$age; fi
    if newer "$version" "$pinned" && [ "$age" -ge "$MIN_AGE_DAYS" ] && { [ -z "$target" ] || newer "$version" "$target"; }; then
      target=$version; target_age=$age; target_date=$date
    fi
  done < "$file"
  [ "$count" -gt 0 ] || die "$app: no release with a version tag listed"
  if [ -n "$target" ]; then
    state="**Bump due**: to $target, released $target_age days ago"; due=1
    if [ -n "${TARGETS_FILE-}" ]; then
      covered=$(for i in "${!versions[@]}"; do
        if newer "${versions[i]}" "$pinned" && ! newer "${versions[i]}" "$target"; then echo "${versions[i]}:${dates[i]}"; fi
      done | sort -t. -k1,1nr -k2,2nr -k3,3nr | paste -s -d, -)
      echo "$app $target $target_date $covered" >> "$TARGETS_FILE"
    fi
  elif newer "$latest" "$pinned"; then
    state="Newer, but none newer than the pin is $MIN_AGE_DAYS days old yet (the latest is $latest_age days old)"
  else
    state='Up to date'
  fi
  [ "$skipped" -eq 0 ] || state="$state. Left out $skipped tag(s) not shaped like a version"
  rows+=("| $app | $pinned | $latest ($latest_date) | $state |")
}
check RustDesk "$rustdesk_mac" "$1"
check Tailscale "$tailscale_mac" "$2"

echo "Pinned versions compared with the releases on $today."
echo
echo '| App | Pinned | Latest release | State |'
echo '|---|---|---|---|'
printf '%s\n' "${rows[@]}"
if [ "$due" -eq 1 ]; then
  cat << 'EOF'

To bump a pin (the Version watch workflow opens a PR that does it), change in both `scripts/mac/tailnet-desk.sh` and `scripts/windows/tailnet-desk.psm1` its version,
the release date in the comment above it, and the SHA-256 values next to it (for RustDesk on a Mac, both disk images:
ARM64 and x86_64), taking the hashes from the official downloads. Then run the tests, try the install on a real
machine, and update the README's Status.
EOF
fi
exit "$due"
