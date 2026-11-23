#!/usr/bin/env bash
# Fails if a Markdown file links to a file, image or heading in this repo that doesn't exist, or to a path outside
# the repo. Only relative links are checked, so the result never depends on the network. A link's #anchor must match a
# heading in the target file (or in the same file, for a bare #anchor), using GitHub's heading-to-anchor rule.
#
# Usage: tools/check-links.sh [file.md ...]
#   With files: checks those (each must exist). Without: every tracked .md file except tests/fixtures/.
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
    case "$f" in tests/fixtures/*) continue ;; esac
    files+=("$f")
  done < <(git ls-files -z -- '*.md')
  if [ "${#files[@]}" -eq 0 ]; then echo "No tracked Markdown files found to check." >&2; exit 2; fi
fi

# Prints the GitHub anchors of a Markdown file's headings, one per line. Duplicates get -1, -2 and so on.
anchors() {
  perl -ne '
    next unless /^#{1,6}\s+(.*?)\s*#*\s*$/;
    my $h = lc $1;
    $h =~ s/[^\w\- ]//g;   # drop punctuation except hyphens and underscores
    $h =~ s/ /-/g;
    my $n = $seen{$h}++;
    print $n ? "$h-$n\n" : "$h\n";
  ' "$1"
}

status=0
for f in "${files[@]}"; do
  [ -L "$f" ] && continue
  dir=$(cd "$(dirname "$f")" && pwd -P)
  # Markdown links and images: ](target) or ](target "title").
  while IFS= read -r hit; do
    line=${hit%%:*}
    target=${hit#*:}
    target=${target#](}
    target=${target%)}
    target=${target%% *}
    case "$target" in
      http://* | https://* | mailto:* | '') continue ;;
    esac
    path=${target%%#*}
    anchor=''
    case "$target" in *'#'*) anchor=${target#*#} ;; esac
    path=${path//%20/ }

    if [ -z "$path" ]; then
      dest="$f"
    else
      dest="$dir/$path"
      if [ -L "$dest" ]; then
        echo "$f:$line: link points at a symlink, which could lead outside the repository: $target"; status=1; continue
      fi
      if [ ! -e "$dest" ]; then
        echo "$f:$line: broken link to $target"; status=1; continue
      fi
      real=$(cd "$(dirname "$dest")" && pwd -P)
      case "$real/" in
        "$(cd "$root" && pwd -P)/"*) ;;
        *) echo "$f:$line: link points outside the repository: $target"; status=1; continue ;;
      esac
    fi

    if [ -n "$anchor" ] && [ -f "$dest" ] && [[ "$dest" == *.md ]]; then
      if ! anchors "$dest" | grep -qxF -- "$anchor"; then
        echo "$f:$line: no heading for #$anchor in ${path:-this file}"; status=1
      fi
    fi
  done < <(grep -noE '\]\([^)]+\)' "$f" || true)
done

if [ "$status" -ne 0 ]; then
  echo "Link check failed." >&2
fi
exit "$status"
