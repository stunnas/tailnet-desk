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
    -h | --help) td_print_help "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
if [ "$(id -u)" -eq 0 ]; then echo 'Run this as yourself, not with sudo: it asks for your password when needed.' >&2; exit 2; fi

findings() {
  local ts_ip
  ts_ip=$(td_tailscale_ipv4)
  td_check 'Tailscale is signed in' 'no Tailscale address' test -n "$ts_ip"
  rustdesk_findings "$ts_ip"
  # The firewall step doesn't depend on RustDesk, so it's checked even when RustDesk isn't running.
  if td_pf_installed; then
    td_check "The firewall step's rules are loaded and pf is on" 'run ./enable-pf.sh again, or ./undo-pf.sh' td_pf_rules_loaded
  fi
}

# RustDesk's checks; later ones need the earlier ones to pass, so it stops at the first that doesn't.
rustdesk_findings() {
  local ts_ip=$1 exe current
  exe=$(td_rustdesk_exe || true)
  td_check 'RustDesk is installed' "not in $TD_RUSTDESK_APP" test -n "$exe"
  [ -n "$exe" ] || return 0
  td_check "RustDesk is signed by its Apple team ($TD_RUSTDESK_TEAM)" 'reinstall it from github.com/rustdesk/rustdesk' \
    td_signed_by_rustdesk "$TD_RUSTDESK_APP"
  td_check 'RustDesk starts at boot (its system service is installed)' \
    'open RustDesk and click Install under "For starting on boot"; Start service alone lasts until the next restart' \
    td_rustdesk_starts_at_boot
  td_check "RustDesk's background service is running" 'open RustDesk and allow its service' td_rustdesk_server_running
  td_rustdesk_server_running || return 0

  # set -e doesn't apply inside this check pipeline, so a failed read is reported here rather than read as empty.
  # shellcheck disable=SC2046 # one key per word, on purpose
  if ! current=$(td_rustdesk_get $(td_host_option_keys)); then
    td_finding 1 "RustDesk's settings could be read" 'quit and reopen RustDesk, check it is allowed in the background'
    return 0
  fi
  printf '%s\n' "$current" | td_host_findings "$given" "$ts_ip"
  if td_option_matches direct-server Y "$(printf '%s\n' "$current" | td_option_value direct-server)"; then
    td_check "RustDesk listens on TCP $TD_DIRECT_PORT" 'nothing listening: quit and reopen RustDesk' td_port_listening "$TD_DIRECT_PORT"
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
