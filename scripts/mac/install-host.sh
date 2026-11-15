#!/bin/bash
# Sets up this Mac as a RustDesk host that only lets your controllers in, over Tailscale.
#
# Run it on the HOST, the Mac that will be controlled, in Terminal as yourself (not with sudo): it asks for your Mac
# password when a step needs it. It is safe to run again: each step skips what is already done, and a run without
# --controller-ip keeps the controllers already whitelisted.
#
#   1. Checks Tailscale is installed and signed in (you install it by hand: see docs/host-mac.md).
#   2. Installs RustDesk (pinned version) from its official GitHub release after checking the disk image's SHA-256
#      and its Apple signing team, if it isn't installed yet.
#   3. Stops until RustDesk's background service and macOS permissions are in place (you click those).
#   4. Sets RustDesk's security settings: no public ID or relay server, permanent password only, sessions start on the
#      password without anyone clicking Accept, no LAN discovery, and direct IP access with only your controllers
#      whitelisted (off until there is a controller).
#   5. Sets the Mac to never sleep while on the charger (skip with --keep-sleep).
#   6. Runs test-host.sh and lists what you still do by hand: the password and two-factor.
#
# The firewall step is separate and optional: enable-pf.sh. It never sets or shows a password.
#
# Usage: ./install-host.sh [--controller-ip 100.64.0.11[,100.64.0.12]] [--keep-sleep]
#   --controller-ip  The Tailscale address (100.x.y.z) of each device allowed to connect. Never this Mac's own.
#                    Leave it out on the first run if no controller is on Tailscale yet.
#   --keep-sleep     Don't change the sleep setting.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/mac/tailnet-desk.sh
. "$here/tailnet-desk.sh"

given=''
keep_sleep=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --controller-ip) [ "$#" -ge 2 ] || { echo '--controller-ip needs an address.' >&2; exit 2; }; given="$given,$2"; shift 2 ;;
    --keep-sleep) keep_sleep=yes; shift ;;
    -h | --help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
if [ "$(id -u)" -eq 0 ]; then echo 'Run this as yourself, not with sudo: it asks for your password when needed.' >&2; exit 2; fi

step() { printf '\n== %s\n' "$1"; }

# Check the given addresses before changing anything.
td_resolve_controllers "$given" > /dev/null

step 'Step 1 of 6: Tailscale'
if ! td_tailscale_cli > /dev/null; then
  echo 'Tailscale is not installed. Install the Standalone app from https://tailscale.com/download/mac,'
  echo 'approve its network extension when macOS asks, sign in, and run this script again.'
  exit 2
fi
my_ip=$(td_tailscale_ipv4)
if [ -z "$my_ip" ]; then
  echo 'Tailscale is installed but not signed in (or not running).'
  echo 'Click the Tailscale icon in the menu bar, choose Log in, and sign in. Then run this script again.'
  exit 2
fi
echo "Tailscale is signed in. This Mac's (the host's) Tailscale address: $my_ip"
# Refuses this Mac's own address before anything else changes.
td_resolve_controllers "$given" '' "$my_ip" > /dev/null

step 'Step 2 of 6: RustDesk'
td_install_rustdesk

step "Step 3 of 6: RustDesk's background service and permissions"
if ! td_rustdesk_server_running; then
  echo "RustDesk's background service isn't running yet. At this Mac:"
  echo '  1. Open RustDesk from Applications. If macOS asks whether to open it, choose Open.'
  echo '  2. When RustDesk asks to install its service, allow it and enter your Mac password.'
  echo '  3. Allow RustDesk in System Settings > Privacy & Security, under both Screen & System Audio Recording and'
  echo '     Accessibility. Quit and reopen RustDesk after each.'
  echo 'Then run this script again.'
  exit 2
fi
echo 'RustDesk is running. Your Mac password may be asked: RustDesk only shows its settings to an administrator.'
# Stop using RustDesk's public ID and relay servers before anything else.
td_rustdesk_set 'custom-rendezvous-server=127.0.0.1' 'relay-server=127.0.0.1'
echo 'RustDesk no longer uses its public servers.'
echo 'Check by hand that Screen & System Audio Recording and Accessibility both list RustDesk as allowed.'

step "Step 4 of 6: RustDesk security settings"
current=$(td_rustdesk_get whitelist)
current=${current#*=}
controllers=$(td_resolve_controllers "$given" "$current" "$my_ip")
controller_args=()
while IFS= read -r ip; do if [ -n "$ip" ]; then controller_args+=("$ip"); fi; done <<< "$controllers"
if [ "${#controller_args[@]}" -gt 0 ]; then
  source='from --controller-ip'
  [ -n "$(td_address_list "$given")" ] || source='kept from before'
  echo "Direct IP access: on. Whitelist ($source): $(IFS=,; echo "${controller_args[*]}")"
else
  echo 'No controller yet, so direct IP access is OFF.'
fi
if [ -z "$(td_address_list "$given")" ]; then
  change=$(td_whitelist_change "$current" ${controller_args[@]+"${controller_args[@]}"})
  if [ -n "$change" ]; then
    echo "Not kept: $(echo "$change" | sed 1d | paste -sd, -). Each isn't a single Tailscale address or is this Mac's own."
    if [ "$(echo "$change" | sed -n 1p)" = removed ]; then
      echo '  They are removed from the whitelist now.'
    else
      echo '  They stay in RustDesk until you run this again with --controller-ip, and the check below fails them.'
    fi
  fi
fi
options=()
while IFS= read -r line; do options+=("$line"); done <<< "$(td_host_options ${controller_args[@]+"${controller_args[@]}"})"
td_rustdesk_set "${options[@]}"

step 'Step 5 of 6: Sleep'
if [ "$keep_sleep" = yes ]; then
  echo 'Left unchanged (--keep-sleep).'
else
  /usr/bin/sudo /usr/bin/pmset -c sleep 0
  echo 'This Mac no longer sleeps while on the charger. (The screen can still turn off.)'
  echo 'On battery, or with the lid closed, it still sleeps: see docs/host-mac.md for keeping a closed Mac awake.'
fi

step 'Step 6 of 6: Check'
check_args=()
[ "${#controller_args[@]}" -eq 0 ] || check_args=(--controller-ip "$(IFS=,; echo "${controller_args[*]}")")
checks=0
"$here/test-host.sh" ${check_args[@]+"${check_args[@]}"} || checks=$?

echo
echo 'Still to do by hand, in RustDesk on this Mac (Settings > Security > Unlock security settings):'
echo '  1. Password: choose "Use permanent password", then "Set permanent password".'
echo '     Use a random 20+ character password from your password manager. Never reuse it.'
echo '  2. Two-factor authentication: turn it on and scan the QR code with your authenticator app.'
echo '     Never photograph or share the QR code: it is the secret.'
if [ "${#controller_args[@]}" -eq 0 ]; then
  echo '  3. When the controller is on Tailscale, run this again with its address, for example:'
  echo "     ./install-host.sh --controller-ip 100.64.0.11   (use the controller's real 100.x address)"
fi
echo 'Optional: limit RustDesk to Tailscale in the firewall too, with ./enable-pf.sh (docs/host-mac.md).'
echo
echo "The controller connects to this Mac's Tailscale address: $my_ip"
[ "$checks" -eq 0 ]
