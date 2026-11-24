#!/usr/bin/env bash
# Compares the RustDesk and Tailscale versions the install scripts pin with the latest releases, and prints a Markdown
# report. It never changes a file: bumping a pin means new SHA-256 values and a re-test, which stay by hand. The
# version-watch workflow looks the releases up and passes them in, so this script itself never uses the network.
#
# Usage: tools/check-versions.sh <rustdesk-tag> <rustdesk-published> <tailscale-tag> <tailscale-published>
#   A tag is a release's tag (1.5.3 or v1.104.7); published is its GitHub publish time (2026-11-09T09:43:52Z).
#   TODAY (YYYY-MM-DD, default today in UTC) sets the date that the releases' ages are counted to.
# Exit: 0 when no pin is due a bump, 1 when a newer release is at least MIN_AGE_DAYS old (the report says which),
# 2 on bad input or when the Mac and Windows pins disagree.
set -euo pipefail

MIN_AGE_DAYS=14 # the repo bumps pins only to releases at least two weeks old

root=$(cd "$(dirname "$0")/.." && pwd)
mac="$root/scripts/mac/tailnet-desk.sh"
win="$root/scripts/windows/tailnet-desk.psm1"

die() { echo "check-versions: $*" >&2; exit 2; }

[ "$#" -eq 4 ] || die 'needs 4 arguments: rustdesk-tag rustdesk-published tailscale-tag tailscale-published (see the header)'

# A version from a tag: 1.2.3, with an optional leading v; anything else is refused, since it comes from outside.
version_of() {
  local v=${1#v}
  [[ $v =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]] || die "not a release version: '$1'"
  echo "$v"
}

# The date part of a GitHub publish time; anything else is refused.
date_of() {
  [[ $1 =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "not a publish time: '$1'"
  echo "${BASH_REMATCH[1]}"
}

# Days since 1970-01-01 for a YYYY-MM-DD date, in plain arithmetic so it works the same with GNU and BSD date.
days_of() {
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) era yoe doy doe
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] || die "not a date: '$1'"
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
[[ $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "TODAY isn't YYYY-MM-DD: '$today'"
today_days=$(days_of "$today")

rustdesk_mac=$(pin "$mac" TD_RUSTDESK_VERSION); rustdesk_win=$(pin "$win" RustDeskVersion)
tailscale_mac=$(pin "$mac" TD_TAILSCALE_VERSION); tailscale_win=$(pin "$win" TailscaleVersion)
[ "$rustdesk_mac" = "$rustdesk_win" ] || die "RustDesk pins disagree: Mac $rustdesk_mac, Windows $rustdesk_win"
[ "$tailscale_mac" = "$tailscale_win" ] || die "Tailscale pins disagree: Mac $tailscale_mac, Windows $tailscale_win"

due=0
rows=()
# Adds one report row for app $1 pinned at $2, whose latest release is tag $3 published at $4.
check() {
  local app=$1 pinned=$2 latest published published_days age state
  latest=$(version_of "$3"); published=$(date_of "$4"); published_days=$(days_of "$published")
  age=$((today_days - published_days))
  if ! newer "$latest" "$pinned"; then
    state='Up to date'
  elif [ "$age" -ge "$MIN_AGE_DAYS" ]; then
    state="**Bump due**: released $age days ago"; due=1
  else
    state="Newer, released $age days ago: due once it's $MIN_AGE_DAYS days old"
  fi
  rows+=("| $app | $pinned | $latest ($published) | $state |")
}
check RustDesk "$rustdesk_mac" "$1" "$2"
check Tailscale "$tailscale_mac" "$3" "$4"

echo "Pinned versions compared with the latest releases on $today."
echo
echo '| App | Pinned | Latest release | State |'
echo '|---|---|---|---|'
printf '%s\n' "${rows[@]}"
if [ "$due" -eq 1 ]; then
  cat << 'EOF'

To bump a pin, change its version and the SHA-256 values next to it in both `scripts/mac/tailnet-desk.sh` and
`scripts/windows/tailnet-desk.psm1`, taking the hashes from the official downloads. Then run the tests, try the
install on a real machine, and update the README's Status.
EOF
fi
exit "$due"
