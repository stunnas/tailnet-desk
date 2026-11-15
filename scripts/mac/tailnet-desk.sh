#!/bin/bash
# tailnet-desk: shared functions for the Mac host and controller scripts. Sourced by them, never run on its own.
# Written for macOS's own /bin/bash, version 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# Sections: settings, checks (no system access; tests/mac covers them), system reads, and system changes. Each system
# change says what it changes. Functions return non-zero and print to stderr on failure. The scripts run with
# set -euo pipefail, so a failure stops them, except inside a check pipeline (findings | td_print_findings || ...),
# where bash turns set -e off: there each step checks its own result and reports a FAIL line instead.
#
# Threat model, as on Windows: the scripts trust the signed-in account and everything running as it. They are run from
# the user's Downloads folder, so a program running as the user could change them anyway. The hardening below protects
# against mistakes and odd setups: programs come from fixed paths, never from PATH, and the downloaded RustDesk disk
# image is checked by SHA-256 and by its Apple-issued signing certificate before anything in it runs.

# --- Settings ------------------------------------------------------------------------------------------------
# Versions are pinned and bumped by hand after testing. The RustDesk version must match scripts/windows/TailnetDesk.psm1
# (tests/mac checks it).

TD_DIRECT_PORT=21118                        # RustDesk direct IP access (TCP)
TD_RUSTDESK_REPO='rustdesk/rustdesk'        # the official GitHub repo; downloads come only from its releases
# Released 2026-11-09. Bump together with both SHA-256 values, then re-test and update the README's Status.
TD_RUSTDESK_VERSION='1.5.3'
TD_RUSTDESK_SHA256_ARM64='e6d30fa1633d772c48935907c208ca4e555a856fb2038af3aaa87a327c29360b'
TD_RUSTDESK_SHA256_X86_64='74d06e6b2e273a128e8d36313e30d47db2063f453a4235ed4d9e5cdfdf9be538'
TD_RUSTDESK_TEAM='HZF9JMC8YN'               # Apple Developer ID team that signs RustDesk's app and disk images
TD_RUSTDESK_APP='/Applications/RustDesk.app'
# RustDesk's startup items, which its Install button ("For starting on boot") creates. Without them, "Start service"
# only runs RustDesk's server until the next restart.
TD_RUSTDESK_AGENT='/Library/LaunchAgents/com.carriez.RustDesk_server.plist'
TD_RUSTDESK_DAEMON='/Library/LaunchDaemons/com.carriez.RustDesk_service.plist'
TD_TAILSCALE_APP='/Applications/Tailscale.app'
TD_TAILSCALE_V4='100.64.0.0/10'             # Tailscale's IPv4 range
TD_TAILSCALE_V6='fd7a:115c:a1e0::/48'       # Tailscale's IPv6 range
TD_PF_ANCHOR='com.apple/tailnet-desk'       # evaluated through Apple's own anchor "com.apple/*" in /etc/pf.conf
TD_PF_DIR='/Library/Application Support/tailnet-desk'
TD_PF_LABEL='io.github.stunnas.tailnet-desk.pf'
TD_PF_PLIST="/Library/LaunchDaemons/$TD_PF_LABEL.plist"
TD_PF_LOG="$TD_PF_DIR/load-pf.log"          # the pf loader's errors, which the failure message points to

# --- Checks (no system access) -------------------------------------------------------------------------------

# True when $1 is exactly one IPv4 address, written without leading zeros.
td_is_ipv4() {
  local a=$1 re='^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' part
  case "$a" in *$'\n'* | *' '*) return 1 ;; esac
  [[ $a =~ $re ]] || return 1
  local IFS=.
  for part in $a; do [ "$part" -le 255 ] || return 1; done
  return 0
}

# True when $1 is one IPv4 address inside Tailscale's range, 100.64.0.0/10 (100.64.0.0 to 100.127.255.255).
td_is_tailscale_ipv4() {
  td_is_ipv4 "$1" || return 1
  local first second rest
  IFS=. read -r first second rest <<< "$1"
  [ "$first" -eq 100 ] && [ "$second" -ge 64 ] && [ "$second" -le 127 ]
}

# True when $1 is one IPv4 address in a private home network range: 10.x, 172.16.x to 172.31.x, or 192.168.x.
# Anything else (a Tailscale, loopback or public address) wouldn't test the host's home network path.
td_is_home_ipv4() {
  td_is_ipv4 "$1" || return 1
  local first second rest
  IFS=. read -r first second rest <<< "$1"
  [ "$first" -eq 10 ] && return 0
  [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ] && return 0
  [ "$first" -eq 192 ] && [ "$second" -eq 168 ] && return 0
  return 1
}

# Prints the addresses in all arguments (each a single address or a comma-separated list) one per line: trimmed, no
# blanks, no repeats, in the order given. It doesn't judge them.
td_address_list() {
  local arg piece seen=$'\n'
  for arg in "$@"; do
    local IFS=,
    for piece in $arg; do
      piece=$(printf '%s' "$piece" | tr -d ' \t\r\n')
      [ -n "$piece" ] || continue
      case "$seen" in *$'\n'"$piece"$'\n'*) continue ;; esac
      seen="$seen$piece"$'\n'
      printf '%s\n' "$piece"
    done
  done
}

# Which controllers to whitelist, one per line: the given ones ($1, comma-separated), or when none are given, the
# single Tailscale addresses already in the whitelist ($2). Never this Mac's own address ($3). Fails on an invalid
# given address or on this Mac's own.
td_resolve_controllers() {
  local given=$1 current=${2-} own=${3-} ip list
  list=$(td_address_list "$given")
  if [ -n "$list" ]; then
    while IFS= read -r ip; do
      if ! td_is_tailscale_ipv4 "$ip"; then
        echo "Not a Tailscale address: '$ip'. Tailscale addresses run from 100.64.0.0 to 100.127.255.255." >&2
        return 2
      fi
      if [ -n "$own" ] && [ "$ip" = "$own" ]; then
        echo "'$ip' is this Mac's own address. Use the controller's address instead." >&2
        return 2
      fi
    done <<< "$list"
    printf '%s\n' "$list"
    return 0
  fi
  # Keep only single Tailscale addresses that aren't this Mac: ranges and home addresses are dropped.
  td_address_list "$current" | while IFS= read -r ip; do
    if td_is_tailscale_ipv4 "$ip" && [ "$ip" != "$own" ]; then printf '%s\n' "$ip"; fi
  done
}

# The RustDesk settings a locked-down host needs, one "key=value" per line, for the controllers given as arguments.
# With controllers, direct IP access is on and only they are whitelisted. Without, it is off and the whitelist is left
# as it is: an empty whitelist would let every device on the Tailscale network try a password, and td_host_findings
# fails any entry that isn't a single Tailscale address. The same settings as scripts/windows/TailnetDesk.psm1.
td_host_options() {
  # Never register with RustDesk's public ID and relay servers: connect by Tailscale address only.
  echo 'custom-rendezvous-server=127.0.0.1'
  echo 'relay-server=127.0.0.1'
  # Only the permanent password works, and a session starts on it (and the two-factor code) alone.
  echo 'verification-method=use-permanent-password'
  echo 'approve-mode=password'
  # Stop answering LAN discovery on UDP 21119.
  echo 'enable-lan-discovery=N'
  if [ "$#" -gt 0 ]; then
    local IFS=,
    echo "whitelist=$*"
    echo 'direct-server=Y'
  else
    echo 'direct-server=N'
  fi
}

# Every RustDesk setting the host checks, one per line: the ones td_host_options sets, plus the whitelist.
td_host_option_keys() {
  { echo whitelist; td_host_options | cut -d= -f1; } | awk '!seen[$0]++'
}

# True when RustDesk's reported value ($3) means the wanted one ($2) for key $1. RustDesk drops a setting that equals
# its default, so an empty value counts as N for direct-server (off by default). Whitelists compare as sets.
td_option_matches() {
  local key=$1 want=$2 have
  have=$(printf '%s' "${3-}" | tr -d ' \t\r\n')
  if [ "$key" = whitelist ]; then
    [ "$(td_address_list "$want" | sort | tr '\n' ,)" = "$(td_address_list "$have" | sort | tr '\n' ,)" ]
    return
  fi
  [ "$have" = "$want" ] && return 0
  [ "$key" = direct-server ] && [ "$want" = N ] && [ -z "$have" ]
}

# What a run without controllers given does to whitelist entries it can't keep: prints "removed" when controllers
# were kept (the whitelist is rewritten to just those), "kept" when none were (it isn't rewritten), then the entries,
# one per line. Prints nothing when every entry was kept. $1 is the current whitelist; the kept controllers follow.
td_whitelist_change() {
  local current=$1 ip not_kept=''
  shift
  # A loop over a here-string, not $( ... ): bash 3.2 can't parse a case pattern inside $( ).
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    td_in_args "$ip" "$@" || not_kept="$not_kept$ip"$'\n'
  done <<< "$(td_address_list "$current")"
  [ -n "$not_kept" ] || return 0
  if [ "$#" -gt 0 ]; then echo removed; else echo kept; fi
  printf '%s' "$not_kept"
}

# The value of setting $1 in "key=value" lines read from stdin (everything after the first =), or nothing.
td_option_value() {
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

# Prints a script's usage: its header comment, from the line after #! to the first line that isn't a comment.
td_print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

# True when $1 equals one of the other arguments.
td_in_args() {
  local want=$1 item
  shift
  for item in "$@"; do [ "$item" = "$want" ] && return 0; done
  return 1
}

# One result line per check: "PASS<tab>check" or "FAIL<tab>check<tab>detail". $1 is 0 for pass, anything else fail.
td_finding() {
  if [ "$1" -eq 0 ]; then printf 'PASS\t%s\n' "$2"; else printf 'FAIL\t%s\t%s\n' "$2" "${3-}"; fi
}

# Runs a test command (the arguments after the check and its failure detail) and prints its result line. The test
# runs inside an if, so a failing check never stops a script that uses set -e.
td_check() {
  local check=$1 detail=$2
  shift 2
  if "$@"; then td_finding 0 "$check"; else td_finding 1 "$check" "$detail"; fi
}

# Checks RustDesk's current settings, read from stdin as "key=value" lines. $1 is the given controllers (comma-
# separated, may be empty), $2 this Mac's Tailscale address. Same rules as the Windows Get-HostSettingFinding:
# given controllers must be valid and exactly whitelisted; every whitelist entry must be one Tailscale address that
# isn't this Mac, even while direct IP access is off; direct IP access on with an empty whitelist fails.
td_host_findings() {
  local given_text=$1 own=${2-} current key value whitelist='' direct='' ip line given basis
  current=$(cat)
  whitelist=$(printf '%s\n' "$current" | td_option_value whitelist)
  direct=$(printf '%s\n' "$current" | td_option_value direct-server)
  given=$(td_address_list "$given_text")

  if [ -n "$given" ]; then
    while IFS= read -r ip; do
      td_check "Given controller address '$ip' is one Tailscale address" \
        'use the 100.x address from the Tailscale admin console; no ranges, no home addresses' td_is_tailscale_ipv4 "$ip"
    done <<< "$given"
  fi
  if td_option_matches direct-server Y "$direct"; then
    td_check 'Whitelist is not empty while direct IP access is on' 'an empty whitelist lets every Tailscale device try a password' \
      test -n "$(td_address_list "$whitelist")"
  fi
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    td_check "Whitelist entry '$ip' is one Tailscale address" \
      'use the 100.x address from the Tailscale admin console; no ranges, no home addresses' td_is_tailscale_ipv4 "$ip"
    if [ -n "$own" ] && [ "$ip" = "$own" ]; then
      td_finding 1 "Whitelist doesn't include this Mac's own address" "remove $own; whitelist only the controllers"
    fi
  done <<< "$(td_address_list "$whitelist")"

  # The wanted settings come from the given controllers, or from the valid entries already whitelisted.
  if [ -n "$given" ]; then
    basis=$(while IFS= read -r ip; do if td_is_tailscale_ipv4 "$ip"; then echo "$ip"; fi; done <<< "$given")
  else
    basis=$(td_address_list "$whitelist" | while IFS= read -r ip; do if td_is_tailscale_ipv4 "$ip"; then echo "$ip"; fi; done)
  fi
  local -a basis_args=()
  while IFS= read -r ip; do if [ -n "$ip" ]; then basis_args+=("$ip"); fi; done <<< "$basis"
  while IFS= read -r line; do
    key=${line%%=*}; value=${line#*=}
    local have
    have=$(printf '%s\n' "$current" | td_option_value "$key")
    td_check "RustDesk setting $key" "want '$value', have '$have'" td_option_matches "$key" "$value" "$have"
  done <<< "$(td_host_options ${basis_args[@]+"${basis_args[@]}"})"
}

# Prints result lines as PASS and FAIL and returns 0 when all passed. No results counts as a failure, so a check that
# found nothing to check never reports success.
td_print_findings() {
  local mark check detail ran=no failed=no
  while IFS=$'\t' read -r mark check detail; do
    [ -n "$mark" ] || continue
    ran=yes
    if [ "$mark" = PASS ]; then
      printf '  PASS  %s\n' "$check"
    else
      failed=yes
      printf '  FAIL  %s  (%s)\n' "$check" "$detail"
    fi
  done
  if [ "$ran" = no ]; then printf '  FAIL  No checks ran\n'; return 1; fi
  [ "$failed" = no ]
}

# The pf rules for the opt-in firewall step: RustDesk's direct port answers only to addresses in Tailscale's ranges, on
# IPv4 and IPv6, whatever the Tailscale interface is called (its utun number changes, and macOS pf can't name a group of
# interfaces). A few networks (carrier-grade NAT) also hand out addresses in 100.64.0.0/10, so on those the port can
# still be reached from that network; RustDesk's whitelist, password and two-factor still apply there.
td_pf_rules() {
  local port=${1:-$TD_DIRECT_PORT}
  echo "# tailnet-desk: RustDesk's direct port $port answers only to addresses in Tailscale's ranges. Undo with undo-pf.sh."
  echo "pass in quick inet proto tcp from $TD_TAILSCALE_V4 to $TD_TAILSCALE_V4 port $port"
  echo "pass in quick inet6 proto tcp from $TD_TAILSCALE_V6 to $TD_TAILSCALE_V6 port $port"
  echo "block drop in quick proto tcp from any to any port $port"
}

# The RustDesk disk image name and its pinned SHA-256 for a machine type ($1, as uname -m prints it), as two lines.
td_rustdesk_asset() {
  case "$1" in
    arm64) printf 'rustdesk-%s-aarch64.dmg\n%s\n' "$TD_RUSTDESK_VERSION" "$TD_RUSTDESK_SHA256_ARM64" ;;
    x86_64) printf 'rustdesk-%s-x86_64.dmg\n%s\n' "$TD_RUSTDESK_VERSION" "$TD_RUSTDESK_SHA256_X86_64" ;;
    *) echo "Unsupported Mac type '$1'." >&2; return 2 ;;
  esac
}

# The token pfctl -E prints ("Token : 123"), read from stdin, or nothing.
td_pf_token_from_output() {
  awk -F': *' '/^Token *:/ { gsub(/[^0-9]/, "", $2); print $2; exit }'
}

# The boot's start time in seconds, from sysctl -n kern.boottime ("{ sec = 123456, usec = ... } ..."), read from
# stdin, or nothing. A saved pf token is only valid in the boot that made it, so it's saved with this.
td_boot_from_sysctl() {
  sed -n 's/.*sec = \([0-9][0-9]*\),.*/\1/p' | head -n 1
}

# The saved token from a token file's text ("<token> <boot>", read from stdin) when it was saved in boot $1, or
# nothing. A token from an earlier boot is never released: by now another program may hold that number.
td_pf_token_for_boot() {
  awk -v boot="$1" '$1 ~ /^[0-9]+$/ && $2 != "" && $2 == boot { print $1; exit }'
}

# Which saved pf token the undo may release, from the token file's text (stdin) and the current boot ($1): prints the
# token when it's from this boot. Returns 3 when a token was saved but can't be released safely (from another boot, or
# the boot time is unknown), so the undo can say pf stays on until a restart. Returns 0 with no output when nothing was
# saved.
td_pf_token_to_release() {
  local saved token
  saved=$(cat)
  [ -n "$(printf '%s' "$saved" | tr -d ' \t\r\n')" ] || return 0
  token=$(printf '%s\n' "$saved" | td_pf_token_for_boot "$1")
  [ -n "$token" ] || return 3
  printf '%s\n' "$token"
}

# --- System reads --------------------------------------------------------------------------------------------

# The Tailscale command line tool: the Standalone or App Store app's own binary, never one found through PATH.
td_tailscale_cli() {
  local exe="$TD_TAILSCALE_APP/Contents/MacOS/Tailscale"
  [ -x "$exe" ] && echo "$exe"
}

# This Mac's Tailscale IPv4 address, or nothing when Tailscale isn't installed or isn't signed in.
td_tailscale_ipv4() {
  local cli out
  cli=$(td_tailscale_cli) || return 0
  out=$("$cli" ip -4 2>/dev/null | tr -d ' \t\r') || return 0
  if td_is_tailscale_ipv4 "$out"; then echo "$out"; fi
}

td_rustdesk_exe() {
  local exe="$TD_RUSTDESK_APP/Contents/MacOS/RustDesk"
  [ -x "$exe" ] && echo "$exe"
}

# The codesign requirement for RustDesk: a certificate Apple issued (anchor apple generic) to RustDesk's team.
td_rustdesk_requirement() {
  printf 'anchor apple generic and certificate leaf[subject.OU] = "%s"' "$TD_RUSTDESK_TEAM"
}

# True when an app or disk image ($1) has a valid signature from a certificate Apple issued to RustDesk's team.
td_signed_by_rustdesk() {
  /usr/bin/codesign --verify --strict -R="$(td_rustdesk_requirement)" "$1" > /dev/null 2>&1
}

# True when RustDesk's startup items are installed, so its server starts at every boot, even before anyone logs in.
td_rustdesk_starts_at_boot() {
  [ -f "$TD_RUSTDESK_AGENT" ] && [ -f "$TD_RUSTDESK_DAEMON" ]
}

# True when RustDesk's background server (the part that accepts connections) is running.
td_rustdesk_server_running() {
  /usr/bin/pgrep -f "$TD_RUSTDESK_APP/Contents/MacOS/RustDesk --server" > /dev/null
}

# Reads RustDesk settings ($@ are keys) through its command line, as "key=value" lines. RustDesk only answers an
# administrator, so this runs it with sudo; -H gives it root's own home. Fails when RustDesk refuses.
td_rustdesk_get() {
  local exe key out
  exe=$(td_rustdesk_exe) || { echo 'RustDesk is not installed.' >&2; return 1; }
  for key in "$@"; do
    out=$(/usr/bin/sudo -H "$exe" --option "$key" 2> /dev/null | tr -d '\r') ||
      { echo "RustDesk couldn't read the setting $key." >&2; return 1; }
    case "$out" in
      *'administrative privileges required'* | *'Settings are disabled'*)
        echo "RustDesk refused to read the setting $key: $out" >&2; return 1 ;;
    esac
    printf '%s=%s\n' "$key" "$(printf '%s' "$out" | head -n 1)"
  done
}

# True when something listens on TCP port $1.
td_port_listening() {
  /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN > /dev/null 2>&1
}

# True when the opt-in pf step's files are installed.
td_pf_installed() {
  [ -f "$TD_PF_PLIST" ] || [ -f "$TD_PF_DIR/pf.rules" ]
}

# --- System changes ------------------------------------------------------------------------------------------

# Writes RustDesk settings (arguments are "key=value"), then reads each back and fails if it didn't take.
# Changes: RustDesk's settings.
td_rustdesk_set() {
  local exe pair key value now
  exe=$(td_rustdesk_exe) || { echo 'RustDesk is not installed.' >&2; return 1; }
  for pair in "$@"; do
    key=${pair%%=*}; value=${pair#*=}
    local said
    said=$(/usr/bin/sudo -H "$exe" --option "$key" "$value" 2>&1 | tr -d '\r' | head -n 3 || true)
    now=$(td_rustdesk_get "$key") || return 1
    now=${now#*=}
    if ! td_option_matches "$key" "$value" "$now"; then
      echo "RustDesk didn't take the setting $key (wanted '$value', reads '$now'). Is RustDesk open and its service installed?" >&2
      [ -z "$said" ] || echo "RustDesk said: $said" >&2
      return 1
    fi
  done
}

# Downloads the pinned RustDesk disk image from its official GitHub release into a new private folder, checks its
# SHA-256 and its Apple signing team, then copies the app into /Applications. Does nothing when RustDesk is already
# installed. Changes: installs a program.
td_install_rustdesk() {
  if td_rustdesk_exe > /dev/null; then echo 'RustDesk is already installed.'; return 0; fi
  local asset name sha tmp dmg mnt actual
  asset=$(td_rustdesk_asset "$(/usr/bin/uname -m)") || return 1
  name=$(echo "$asset" | sed -n 1p); sha=$(echo "$asset" | sed -n 2p)
  tmp=$(/usr/bin/mktemp -d) || return 1        # mktemp -d makes a folder only this user can open
  dmg="$tmp/$name"; mnt="$tmp/mount"
  echo "Downloading RustDesk $TD_RUSTDESK_VERSION from github.com/$TD_RUSTDESK_REPO ..."
  if ! /usr/bin/curl -fsSL --proto '=https' --retry 3 -o "$dmg" \
      "https://github.com/$TD_RUSTDESK_REPO/releases/download/$TD_RUSTDESK_VERSION/$name"; then
    rm -rf "$tmp"; echo "Couldn't download $name. Check the internet connection and try again." >&2; return 1
  fi
  actual=$(/usr/bin/shasum -a 256 "$dmg" | awk '{ print $1 }')
  if [ "$actual" != "$sha" ]; then
    rm -rf "$tmp"; echo "The download's SHA-256 doesn't match the pinned one. Nothing was installed." >&2; return 1
  fi
  echo 'SHA-256 matches the pinned value.'
  if ! td_signed_by_rustdesk "$dmg"; then
    rm -rf "$tmp"; echo "The disk image isn't signed by RustDesk's Apple team. Nothing was installed." >&2; return 1
  fi
  mkdir "$mnt"
  if ! /usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" > /dev/null; then
    rm -rf "$tmp"; echo "Couldn't open the disk image." >&2; return 1
  fi
  if ! td_signed_by_rustdesk "$mnt/RustDesk.app"; then
    /usr/bin/hdiutil detach -quiet "$mnt" || true; rm -rf "$tmp"
    echo "The app in the disk image isn't signed by RustDesk's Apple team. Nothing was installed." >&2; return 1
  fi
  echo 'Copying RustDesk to Applications (your Mac password may be asked) ...'
  /usr/bin/sudo /usr/bin/ditto "$mnt/RustDesk.app" "$TD_RUSTDESK_APP"
  /usr/bin/hdiutil detach -quiet "$mnt" || true
  rm -rf "$tmp"
  if ! td_signed_by_rustdesk "$TD_RUSTDESK_APP"; then
    echo "RustDesk in Applications isn't signed by RustDesk's Apple team after copying. Delete it and run again." >&2
    return 1
  fi
}

# Installs the opt-in pf step: the rules, a loader that enables pf with its own reference and loads the rules, and a
# startup item that runs the loader at every boot. Then runs the loader now. Changes: files under TD_PF_DIR and
# /Library/LaunchDaemons, and the running packet filter.
td_pf_enable() {
  local tmp
  tmp=$(/usr/bin/mktemp -d) || return 1
  td_pf_rules > "$tmp/pf.rules"
  td_pf_loader > "$tmp/load-pf.sh"
  td_pf_plist > "$tmp/plist"
  /usr/bin/sudo /bin/mkdir -p "$TD_PF_DIR"
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$tmp/pf.rules" "$TD_PF_DIR/pf.rules"
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 755 "$tmp/load-pf.sh" "$TD_PF_DIR/load-pf.sh"
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$tmp/plist" "$TD_PF_PLIST"
  rm -rf "$tmp"
  /usr/bin/sudo /bin/launchctl bootout system "$TD_PF_PLIST" 2> /dev/null || true
  /usr/bin/sudo /bin/launchctl bootstrap system "$TD_PF_PLIST"
  # The startup item runs the loader once when it's loaded; wait for its rules to appear.
  local tries=0
  while [ "$tries" -lt 5 ]; do
    td_pf_rules_loaded && return 0
    sleep 1
    tries=$((tries + 1))
  done
  echo "The pf rules didn't load. The loader's errors are in $TD_PF_LOG (read it with: sudo cat \"$TD_PF_LOG\")." >&2
  return 1
}

# True when the pf step's rules are in the running packet filter and pf is enabled.
td_pf_rules_loaded() {
  /usr/bin/sudo /sbin/pfctl -a "$TD_PF_ANCHOR" -s rules 2> /dev/null | grep -q "port = $TD_DIRECT_PORT" &&
    /usr/bin/sudo /sbin/pfctl -s info 2> /dev/null | grep -q 'Status: Enabled'
}

# Undo for td_pf_enable: removes the rules, releases this step's pf reference (pf stays on if anything else uses it),
# and deletes the startup item and files. Returns 3, after saying why, when the reference couldn't be released, so pf
# stays on until the Mac restarts. Changes: the running packet filter, and the files td_pf_enable wrote.
td_pf_disable() {
  /usr/bin/sudo /bin/launchctl bootout system "$TD_PF_PLIST" 2> /dev/null || true
  /usr/bin/sudo /sbin/pfctl -a "$TD_PF_ANCHOR" -F all 2> /dev/null || true
  local token boot status=0 err
  boot=$(/usr/sbin/sysctl -n kern.boottime | td_boot_from_sysctl)
  if token=$(/usr/bin/sudo /bin/cat "$TD_PF_DIR/token" 2> /dev/null | td_pf_token_to_release "$boot"); then
    # Never pfctl -d: that would stop pf for everything. Release only this step's own reference.
    if [ -n "$token" ] && ! err=$(/usr/bin/sudo /sbin/pfctl -X "$token" 2>&1); then
      echo "Couldn't release this step's pf reference: $err" >&2
      status=3
    fi
  else
    echo "This step's pf reference was saved in an earlier boot (or the boot time can't be read), so it isn't released." >&2
    status=3
  fi
  /usr/bin/sudo /bin/rm -f "$TD_PF_PLIST" "$TD_PF_DIR/pf.rules" "$TD_PF_DIR/load-pf.sh" "$TD_PF_DIR/token" "$TD_PF_LOG"
  /usr/bin/sudo /bin/rmdir "$TD_PF_DIR" 2> /dev/null || true
  return "$status"
}

# The loader the startup item runs as root. It takes a new pf reference first (pfctl -E, which keeps pf on until every
# holder lets go), and only once that worked releases the reference an earlier run took in this same boot (when
# enable-pf.sh runs again before a restart), so pf never goes off in between. It saves the new token with the boot's
# start time for the undo, and loads the rules into this step's anchor. A token from an earlier boot is dropped, never
# released. When it can't read the boot time or gets no token, it stops with the reason in TD_PF_LOG (emptied first)
# and leaves an earlier token as it was. It uses the library's own parsing functions, so the parsing the tests check is
# the parsing that runs.
td_pf_loader() {
  cat << EOF
#!/bin/bash
# tailnet-desk pf loader, written by enable-pf.sh. Runs at boot as root. Undo with undo-pf.sh.
set -eu
dir='$TD_PF_DIR'
log='$TD_PF_LOG'
$(declare -f td_pf_token_from_output td_boot_from_sysctl td_pf_token_for_boot)
: > "\$log" 2> /dev/null || true
boot=\$(/usr/sbin/sysctl -n kern.boottime | td_boot_from_sysctl)
if [ -z "\$boot" ]; then
  echo "Couldn't read the boot time (sysctl kern.boottime), so the pf reference couldn't be saved safely." >&2
  exit 1
fi
old=\$(cat "\$dir/token" 2> /dev/null | td_pf_token_for_boot "\$boot" || true)
out=\$(/sbin/pfctl -E 2>&1) || true
token=\$(printf '%s\n' "\$out" | td_pf_token_from_output)
if [ -z "\$token" ]; then
  printf 'pfctl -E gave no token, so pf may not be on:\n%s\n' "\$out" >&2
  exit 1
fi
if [ -n "\$old" ] && [ "\$old" != "\$token" ]; then /sbin/pfctl -X "\$old" > /dev/null 2>&1 || true; fi
printf '%s %s\n' "\$token" "\$boot" > "\$dir/token"
/sbin/pfctl -a '$TD_PF_ANCHOR' -f "\$dir/pf.rules"
EOF
}

td_pf_plist() {
  cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$TD_PF_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$TD_PF_DIR/load-pf.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$TD_PF_LOG</string>
</dict>
</plist>
EOF
}
