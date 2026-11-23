#!/bin/bash
# Undoes enable-pf.sh: removes its firewall rules and startup item, and releases its pf reference. pf stays on if
# something else on the Mac uses it. RustDesk's whitelist, password and two-factor stay as they are.
#
# Run it on the HOST in Terminal as yourself: it asks for your Mac password.
#
# Usage: ./undo-pf.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/tailnet-desk.sh
. "$here/tailnet-desk.sh"

case "${1-}" in
  '') ;;
  -h | --help) td_print_help "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac
if [ "$(id -u)" -eq 0 ]; then echo 'Run this as yourself, not with sudo: it asks for your password when needed.' >&2; exit 2; fi

# The step's rules can outlive its files (for example after deleting them by hand), so check both.
anchor_rules() { /usr/bin/sudo /sbin/pfctl -a "$TD_PF_ANCHOR" -s rules 2> /dev/null | grep -q .; }
if ! td_pf_installed && ! anchor_rules; then
  echo "The firewall step isn't installed, so there is nothing to undo."
  exit 1
fi
released=0
td_pf_disable || released=$?
if td_pf_installed || anchor_rules; then
  echo "Something of the firewall step is still there. Restart the Mac and run this again." >&2
  exit 1
fi
echo "Done. RustDesk's port answers on every network again; the whitelist still limits who can connect."
if [ "$released" -eq 0 ]; then
  echo 'If nothing else on the Mac uses pf, macOS turns iCloud Private Relay back on.'
else
  echo 'pf itself stays on until you restart the Mac (its rules for RustDesk are gone). Private Relay comes back after'
  echo 'the restart if nothing else on the Mac uses pf.'
fi
