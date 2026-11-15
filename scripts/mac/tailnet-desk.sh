#!/bin/bash
# tailnet-desk: shared functions for the Mac host and controller scripts. Sourced by them, never run on its own.
# Written for macOS's own /bin/bash, version 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# Sections: settings, checks (no system access; tests/mac covers them), system reads, and system changes. Each system
# change says what it changes. Functions return non-zero and print to stderr on failure; the scripts run with
# set -euo pipefail, so a failure stops them.
#
# Threat model, as on Windows: the scripts trust the signed-in account and everything running as it. They are run from
# the user's Downloads folder, so a program running as the user could change them anyway. The hardening below protects
# against mistakes and odd setups: programs come from fixed paths, never from PATH, and the downloaded RustDesk disk
# image is checked by SHA-256 and by its Apple signing team before anything in it runs.

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
TD_TAILSCALE_APP='/Applications/Tailscale.app'
TD_TAILSCALE_V4='100.64.0.0/10'             # Tailscale's IPv4 range
TD_TAILSCALE_V6='fd7a:115c:a1e0::/48'       # Tailscale's IPv6 range
TD_PF_ANCHOR='com.apple/tailnet-desk'       # evaluated through Apple's own anchor "com.apple/*" in /etc/pf.conf
TD_PF_DIR='/Library/Application Support/tailnet-desk'
TD_PF_LABEL='io.github.stunnas.tailnet-desk.pf'
TD_PF_PLIST="/Library/LaunchDaemons/$TD_PF_LABEL.plist"

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
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*}; value=${line#*=}
    case "$key" in whitelist) whitelist=$value ;; direct-server) direct=$value ;; esac
  done <<< "$current"
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
    have=$(printf '%s\n' "$current" | awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }')
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

# The pf rules for the opt-in firewall step: RustDesk's direct port answers only to Tailscale addresses, on IPv4 and
# IPv6, whatever the Tailscale interface is called (its utun number changes). RustDesk's whitelist stays a second check.
td_pf_rules() {
  local port=${1:-$TD_DIRECT_PORT}
  echo "# tailnet-desk: RustDesk's direct port $port answers only to Tailscale addresses. Undo with undo-pf.sh."
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

# The signing team in codesign -dv output (read from stdin), or nothing.
td_team_from_codesign() {
  awk -F= '/^TeamIdentifier=/ { print $2; exit }'
}

# The token pfctl -E prints ("Token : 123"), read from stdin, or nothing.
td_pf_token_from_output() {
  awk -F': *' '/^Token *:/ { gsub(/[^0-9]/, "", $2); print $2; exit }'
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

# The signing team of an app or disk image ($1), or nothing when it isn't validly signed.
td_signing_team() {
  /usr/bin/codesign --verify --strict "$1" 2>/dev/null || return 0
  /usr/bin/codesign -dv "$1" 2>&1 | td_team_from_codesign
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
    /usr/bin/sudo -H "$exe" --option "$key" "$value" > /dev/null 2>&1 || true
    now=$(td_rustdesk_get "$key") || return 1
    now=${now#*=}
    if ! td_option_matches "$key" "$value" "$now"; then
      echo "RustDesk didn't take the setting $key (wanted '$value', reads '$now'). Is RustDesk open and its service installed?" >&2
      return 1
    fi
  done
}

# Downloads the pinned RustDesk disk image from its official GitHub release into a new private folder, checks its
# SHA-256 and its Apple signing team, then copies the app into /Applications. Does nothing when RustDesk is already
# installed. Changes: installs a program.
td_install_rustdesk() {
  if td_rustdesk_exe > /dev/null; then echo 'RustDesk is already installed.'; return 0; fi
  local asset name sha tmp dmg mnt actual team
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
  team=$(td_signing_team "$dmg")
  if [ "$team" != "$TD_RUSTDESK_TEAM" ]; then
    rm -rf "$tmp"; echo "The disk image isn't signed by RustDesk's Apple team. Nothing was installed." >&2; return 1
  fi
  mkdir "$mnt"
  if ! /usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" > /dev/null; then
    rm -rf "$tmp"; echo "Couldn't open the disk image." >&2; return 1
  fi
  team=$(td_signing_team "$mnt/RustDesk.app")
  if [ "$team" != "$TD_RUSTDESK_TEAM" ]; then
    /usr/bin/hdiutil detach -quiet "$mnt" || true; rm -rf "$tmp"
    echo "The app in the disk image isn't signed by RustDesk's Apple team. Nothing was installed." >&2; return 1
  fi
  echo 'Copying RustDesk to Applications (your Mac password may be asked) ...'
  /usr/bin/sudo /usr/bin/ditto "$mnt/RustDesk.app" "$TD_RUSTDESK_APP"
  /usr/bin/hdiutil detach -quiet "$mnt" || true
  rm -rf "$tmp"
  if [ "$(td_signing_team "$TD_RUSTDESK_APP")" != "$TD_RUSTDESK_TEAM" ]; then
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
  echo "The pf rules didn't load. See /var/log/system.log for tailnet-desk." >&2
  return 1
}

# True when the pf step's rules are in the running packet filter and pf is enabled.
td_pf_rules_loaded() {
  /usr/bin/sudo /sbin/pfctl -a "$TD_PF_ANCHOR" -s rules 2> /dev/null | grep -q "port = $TD_DIRECT_PORT" &&
    /usr/bin/sudo /sbin/pfctl -s info 2> /dev/null | grep -q 'Status: Enabled'
}

# Undo for td_pf_enable: removes the rules, releases this step's pf reference (pf stays on if anything else uses it),
# and deletes the startup item and files. Changes: the running packet filter, and the files td_pf_enable wrote.
td_pf_disable() {
  /usr/bin/sudo /bin/launchctl bootout system "$TD_PF_PLIST" 2> /dev/null || true
  /usr/bin/sudo /sbin/pfctl -a "$TD_PF_ANCHOR" -F all 2> /dev/null || true
  local token
  token=$(/usr/bin/sudo /bin/cat "$TD_PF_DIR/token" 2> /dev/null || true)
  case "$token" in
    '' | *[!0-9]*) ;;
    *) /usr/bin/sudo /sbin/pfctl -X "$token" 2> /dev/null || true ;;   # never pfctl -d: that would stop pf for everything
  esac
  /usr/bin/sudo /bin/rm -f "$TD_PF_PLIST" "$TD_PF_DIR/pf.rules" "$TD_PF_DIR/load-pf.sh" "$TD_PF_DIR/token"
  /usr/bin/sudo /bin/rmdir "$TD_PF_DIR" 2> /dev/null || true
}

# The loader the startup item runs as root: take a pf reference (pfctl -E, which keeps pf on until every holder lets
# go), save its token for the undo, and load the rules into this step's anchor.
td_pf_loader() {
  cat << EOF
#!/bin/bash
# tailnet-desk pf loader, written by enable-pf.sh. Runs at boot as root. Undo with undo-pf.sh.
set -eu
dir='$TD_PF_DIR'
out=\$(/sbin/pfctl -E 2>&1 || true)
token=\$(printf '%s\n' "\$out" | awk -F': *' '/^Token *:/ { gsub(/[^0-9]/, "", \$2); print \$2; exit }')
if [ -n "\$token" ]; then printf '%s\n' "\$token" > "\$dir/token"; fi
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
</dict>
</plist>
EOF
}
