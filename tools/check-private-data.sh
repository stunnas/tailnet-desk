#!/usr/bin/env bash
# Fails if a tracked file contains something that looks like a real address or RustDesk ID.
# This repo is public, and guides are written from real setups, so a pasted address is the likely leak.
#
# Allowed, because they're examples or fixed values, not anyone's real device:
#   100.64.0.10, 100.64.0.11   example Tailscale addresses used in guides and tests
#   192.168.0.10               example home address used in guides and tests
#   100.64.0.0 and 100.127.255.255 (the ends of 100.64.0.0/10), 127.0.0.1, 0.0.0.0
# Everything else that looks like an IPv4 address, a global IPv6 address or a 9 to 10 digit RustDesk ID fails.
#
# Usage: tools/check-private-data.sh [file ...]   (no files: every tracked file except made-up test data)
set -euo pipefail

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r -d '' f; do
    # Made-up test values live in tests/fixtures/, this check's own tests and the Pester tests (range boundaries).
    case "$f" in tests/fixtures/* | tests/tools/check-private-data.bats | tests/windows/*) continue ;; esac
    files+=("$f")
  done < <(git ls-files -z)
fi

status=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  # Skip binary files such as screenshots.
  if [ -s "$f" ] && ! grep -Iq . "$f" 2>/dev/null; then continue; fi

  if ! perl -ne '
    BEGIN { $bad = 0; %ok = map { $_ => 1 } qw(100.64.0.0 100.127.255.255 100.64.0.10 100.64.0.11 192.168.0.10 127.0.0.1 0.0.0.0); }
    # IPv4: not glued to other digits or dots, so version numbers like 1.2.3.4.5 do not count; a full stop after is fine.
    while (/(?<![\d.])((?:\d{1,3}\.){3}\d{1,3})(?!\.?\d)/g) {
      next if $ok{$1};
      print "$ARGV:$.: IPv4 address $1 (use an example address: see tools/check-private-data.sh)\n"; $bad = 1;
    }
    # Global IPv6 (2000::/3) with at least four groups, e.g. 2605:a601:...
    while (/(?<![0-9a-f:])([23][0-9a-f]{3}(?::[0-9a-f]{0,4}){3,7})/gi) {
      print "$ARGV:$.: IPv6 address $1\n"; $bad = 1;
    }
    # RustDesk IDs are 9 or 10 digits standing alone (digits inside hashes have letters next to them).
    while (/(?<![0-9A-Za-z_])(\d{9,10})(?![0-9A-Za-z_])/g) {
      print "$ARGV:$.: number that could be a RustDesk ID: $1\n"; $bad = 1;
    }
    END { exit $bad }
  ' "$f"; then
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "Private data check failed: replace real addresses and IDs with examples." >&2
fi
exit "$status"
