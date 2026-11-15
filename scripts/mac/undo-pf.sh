#!/bin/bash
# Undoes enable-pf.sh: removes its firewall rules and startup item, and releases its pf reference. pf stays on if
# something else on the Mac uses it. RustDesk's whitelist, password and two-factor stay as they are.
#
# Run it on the HOST in Terminal as yourself: it asks for your Mac password.
#
# Usage: ./undo-pf.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/mac/tailnet-desk.sh
. "$here/tailnet-desk.sh"

case "${1-}" in
  '') ;;
  -h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac
if [ "$(id -u)" -eq 0 ]; then echo 'Run this as yourself, not with sudo: it asks for your password when needed.' >&2; exit 2; fi

if ! td_pf_installed; then
  echo "The firewall step isn't installed, so there is nothing to undo."
  exit 1
fi
td_pf_disable
if td_pf_installed || /usr/bin/sudo /sbin/pfctl -a "$TD_PF_ANCHOR" -s rules 2> /dev/null | grep -q .; then
  echo "Something of the firewall step is still there. Run this again, or see docs/host-mac.md." >&2
  exit 1
fi
echo "Done. RustDesk's port answers on every network again; the whitelist still limits who can connect."
echo 'If nothing else uses pf, macOS turns iCloud Private Relay back on within a minute.'
