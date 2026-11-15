#!/bin/bash
# Optional firewall step for a Mac HOST: RustDesk's direct port (TCP 21118) answers only to Tailscale addresses, on
# every network, and keeps doing so after a restart. RustDesk's whitelist stays a second lock.
#
# It uses pf, the Mac's built-in packet filter, through an anchor under Apple's own "com.apple/*" (so /etc/pf.conf is
# never edited), plus a startup item that reloads the rule at every boot. It takes its own pf reference, so it never
# turns pf off for anything else. Undo everything with ./undo-pf.sh.
#
# Run it on the HOST in Terminal as yourself: it asks for your Mac password. Run test-from-controller.sh on the
# controller afterwards: the home network test must show the port closed.
#
# Usage: ./enable-pf.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/mac/tailnet-desk.sh
. "$here/tailnet-desk.sh"

case "${1-}" in
  '') ;;
  -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac
if [ "$(id -u)" -eq 0 ]; then echo 'Run this as yourself, not with sudo: it asks for your password when needed.' >&2; exit 2; fi

echo 'These rules go into the firewall (your Mac password may be asked):'
td_pf_rules | sed 's/^/  /'
td_pf_enable
echo
echo "Done. RustDesk's port $TD_DIRECT_PORT now answers only to Tailscale addresses, also after a restart."
echo 'Check from the controller with test-from-controller.sh, including --host-home-ip. Undo with ./undo-pf.sh.'
echo 'While pf is on, macOS turns off iCloud Private Relay. The undo turns it back on.'
