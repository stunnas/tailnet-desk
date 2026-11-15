#!/usr/bin/env bash
# Fails if a tracked file contains something that looks like a real address, Tailscale name or RustDesk ID.
# This repo is public, and guides are written from real setups, so a pasted address is the likely leak.
#
# Allowed, because they're examples or fixed values, not anyone's real device:
#   100.64.0.10                  example HOST Tailscale address
#   100.64.0.11, 100.64.0.12     example CONTROLLER Tailscale addresses
#   192.168.0.10                 example host home address
#   100.64.0.0, 100.127.255.255  the ends of Tailscale's range 100.64.0.0/10
#   127.0.0.1, 0.0.0.0
# A line containing "check-private-data: allow" is skipped: use it only for made-up test values, such as range
# boundaries in tests, never to let a real value through.
#
# Fails on: other IPv4 addresses; global IPv6 (2000::/3) and Tailscale IPv6 (fd7a:115c:a1e0::/48) addresses; check-private-data: allow
# MagicDNS names (*.ts.net, which name the tailnet); 9 or 10 digit numbers, plain or spaced as RustDesk shows them
# ("123 456 789"), which could be RustDesk IDs. check-private-data: allow
#
# Usage: tools/check-private-data.sh [file ...]
#   With files: checks those paths, read from the current folder (each must exist). Without: every file git tracks,
#   from the repository root, except tests/fixtures/ (planted values the CI checks expect to fail) and this check's
#   own tests.
set -euo pipefail

root=$(git rev-parse --show-toplevel)

files=()
if [ "$#" -gt 0 ]; then
  for f in "$@"; do
    if [ ! -f "$f" ]; then echo "$f: no such file" >&2; exit 2; fi
    files+=("$f")
  done
else
  cd "$root"
  while IFS= read -r -d '' f; do
    case "$f" in tests/fixtures/* | tests/tools/check-private-data.bats) continue ;; esac
    files+=("$f")
  done < <(git ls-files -z)
  if [ "${#files[@]}" -eq 0 ]; then echo "No tracked files found to check." >&2; exit 2; fi
fi

status=0
for f in "${files[@]}"; do
  # Skip symlinks (they could point outside the repo), deleted files and binary files such as screenshots. A file is
  # binary when it has a NUL byte; that's checked byte by byte, so the locale can't make a UTF-8 guide count as binary.
  [ -L "$f" ] && continue
  [ -f "$f" ] || continue
  if ! perl -0777 -ne 'exit(/\0/ ? 1 : 0)' "$f"; then continue; fi

  if ! perl -ne '
    BEGIN {
      $bad = 0;
      %ok = map { $_ => 1 } qw(100.64.0.10 100.64.0.11 100.64.0.12 192.168.0.10 100.64.0.0 100.127.255.255 127.0.0.1 0.0.0.0);
    }
    next if /check-private-data: allow/;
    # IPv4: not glued to other digits or dots, so version numbers like 1.2.3.4.5 do not count; a full stop after is fine.
    while (/(?<![\d.])((?:\d{1,3}\.){3}\d{1,3})(?!\.?\d)/g) {
      next if $ok{$1};
      print "$ARGV:$.: IPv4 address $1 (use an example address: see tools/check-private-data.sh)\n"; $bad = 1;
    }
    # Global IPv6 (2000::/3) and Tailscale IPv6 (fd7a:115c:a1e0::/48), full or compressed. check-private-data: allow
    while (/(?<![0-9a-f:])((?:[23][0-9a-f]{3}|fd7a)(?::[0-9a-f]{0,4}){2,7})/gi) {
      print "$ARGV:$.: IPv6 address $1\n"; $bad = 1;
    }
    # MagicDNS names reveal the tailnet name.
    while (/([a-z0-9-]+(?:\.[a-z0-9-]+)*\.ts\.net)\b/gi) {
      print "$ARGV:$.: Tailscale MagicDNS name $1\n"; $bad = 1;
    }
    # RustDesk IDs: 9 or 10 digits standing alone, or in groups of three separated by single spaces.
    while (/(?<![0-9A-Za-z_])(\d{9,10}|\d{1,3}(?: \d{3}){2,3})(?![0-9A-Za-z_])/g) {
      my $id = $1; (my $digits = $id) =~ s/ //g;
      next unless length($digits) >= 9 && length($digits) <= 10;
      print "$ARGV:$.: number that could be a RustDesk ID: $id\n"; $bad = 1;
    }
    END { exit $bad }
  ' "$f"; then
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "Private data check failed: replace real addresses, names and IDs with examples." >&2
fi
exit "$status"
