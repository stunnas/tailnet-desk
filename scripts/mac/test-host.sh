#!/bin/bash
# Checks that this Mac is set up as a locked-down RustDesk host. Changes nothing.
#
# Run it on the HOST in Terminal as yourself: it asks for your Mac password, because RustDesk only shows its settings
# to an administrator and the firewall can only be read as one. Prints PASS or FAIL for each check and exits with 1 if
# anything failed. Each FAIL line is explained in docs/host-mac.md, "When something goes wrong".
#
# It can't see the password, two-factor or macOS permission settings; check those in RustDesk and System Settings.
#
# Usage: ./test-host.sh [--controller-ip 100.64.0.11[,100.64.0.12]]
#   --controller-ip  The Tailscale addresses that should be whitelisted. Leave it out to judge whatever the whitelist holds.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/mac/tailnet-desk.sh
. "$here/tailnet-desk.sh"

given=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --controller-ip) [ "$#" -ge 2 ] || { echo '--controller-ip needs an address.' >&2; exit 2; }; given="$given,$2"; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
if [ "$(id -u)" -eq 0 ]; then echo 'Run this as yourself, not with sudo: it asks for your password when needed.' >&2; exit 2; fi

findings() {
  local ts_ip exe current
  ts_ip=$(td_tailscale_ipv4)
  td_check 'Tailscale is signed in' 'no Tailscale address' test -n "$ts_ip"

  exe=$(td_rustdesk_exe || true)
  td_check 'RustDesk is installed' "not in $TD_RUSTDESK_APP" test -n "$exe"
  [ -n "$exe" ] || return 0
  td_check "RustDesk is signed by its Apple team ($TD_RUSTDESK_TEAM)" 'reinstall it from github.com/rustdesk/rustdesk' \
    test "$(td_signing_team "$TD_RUSTDESK_APP")" = "$TD_RUSTDESK_TEAM"
  td_check "RustDesk's background service is running" 'open RustDesk and allow its service' td_rustdesk_server_running
  td_rustdesk_server_running || return 0

  # shellcheck disable=SC2046 # one key per word, on purpose
  current=$(td_rustdesk_get $(td_host_option_keys))
  printf '%s\n' "$current" | td_host_findings "$given" "$ts_ip"
  if td_option_matches direct-server Y "$(printf '%s\n' "$current" | awk -F= '$1 == "direct-server" { print $2 }')"; then
    td_check "RustDesk listens on TCP $TD_DIRECT_PORT" 'nothing listening: quit and reopen RustDesk' td_port_listening "$TD_DIRECT_PORT"
  fi

  if td_pf_installed; then
    td_check "The firewall step's rules are loaded and pf is on" 'run ./enable-pf.sh again, or ./undo-pf.sh' td_pf_rules_loaded
  fi
}

echo
echo 'Host checks'
ok=0
findings | td_print_findings || ok=$?
if ! td_pf_installed; then
  echo '  NOTE  The optional firewall step (enable-pf.sh) isn'"'"'t in use; the whitelist alone limits who can connect.'
fi
echo
if [ "$ok" -eq 0 ]; then
  echo 'All host checks passed. Now run test-from-controller.sh on the controller.'
  exit 0
fi
echo 'Some checks failed. See docs/host-mac.md, "When something goes wrong".'
exit 1
