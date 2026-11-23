#!/bin/bash
# From a Mac CONTROLLER, checks that the host answers over Tailscale and not over the home network. Changes nothing.
#
# Run it on the controller (the Mac you sit at), in Terminal as yourself. Never run it on the host: a firewall doesn't
# filter a computer's connections to its own addresses, so the tests would always pass there. For the home network
# test, the controller must be on the same home network as the host. Works with a Windows or a Mac host.
#
# Usage: ./test-from-controller.sh --host-tailscale-ip 100.64.0.10 [--host-home-ip 192.168.0.10]
#   --host-tailscale-ip  The HOST's Tailscale address (100.x.y.z), from the Tailscale admin console.
#   --host-home-ip       The HOST's home network address. Leave it out to skip the home network test, for example
#                        when you're away from home.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/tailnet-desk.sh
. "$here/tailnet-desk.sh"

host_ts=''
host_home=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host-tailscale-ip) [ "$#" -ge 2 ] || { echo "$1 needs an address." >&2; exit 2; }; host_ts=$2; shift 2 ;;
    --host-home-ip) [ "$#" -ge 2 ] || { echo "$1 needs an address." >&2; exit 2; }; host_home=$2; shift 2 ;;
    -h | --help) td_print_help "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if ! td_is_tailscale_ipv4 "$host_ts"; then
  echo "Not a Tailscale address: '$host_ts'. Tailscale addresses run from 100.64.0.0 to 100.127.255.255." >&2
  exit 2
fi
# A typo, a name, or a loopback or public address would make the home test pass without reaching the host.
if [ -n "$host_home" ] && ! td_is_home_ipv4 "$host_home"; then
  echo "Not a home network address: '$host_home'. Use the host's private address (192.168.x.x, 10.x.x.x or 172.16-31.x.x)." >&2
  exit 2
fi
my_ip=$(td_tailscale_ipv4)
if [ -n "$my_ip" ] && [ "$my_ip" = "$host_ts" ]; then
  echo "That's this Mac's own address. Run this on the controller, with the host's address." >&2
  exit 2
fi

# True when a TCP connection to $1 on RustDesk's direct port succeeds within 3 seconds.
reachable() { /usr/bin/nc -z -G 3 "$1" "$TD_DIRECT_PORT" > /dev/null 2>&1; }

findings() {
  td_check 'This Mac is signed in to Tailscale' 'no Tailscale address' test -n "$my_ip"
  td_check "Host's Tailscale address answers on $TD_DIRECT_PORT" 'want open, have closed' reachable "$host_ts"
  if [ -n "$host_home" ]; then
    if reachable "$host_home"; then
      td_finding 1 "Host's home address does NOT answer on $TD_DIRECT_PORT" 'want closed, have open'
    else
      td_finding 0 "Host's home address does NOT answer on $TD_DIRECT_PORT"
    fi
  fi
}

echo
echo 'Controller checks'
ok=0
findings | td_print_findings || ok=$?
echo
[ -n "$host_home" ] || echo 'Skipped the home network test (no --host-home-ip).'
echo 'Still test by hand: connecting from a device NOT on the whitelist must show "Your ip is blocked by the peer".'
exit "$ok"
