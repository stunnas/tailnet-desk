#!/usr/bin/env bash
# Fails if a Markdown file links to a file or image in this repo that doesn't exist.
# Only relative links are checked, so the result never depends on the network. Anchors (#...) are ignored.
#
# Usage: tools/check-links.sh [file.md ...]   (no files: every tracked .md file, except tests/fixtures/)
set -euo pipefail

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r -d '' f; do
    case "$f" in tests/fixtures/*) continue ;; esac
    files+=("$f")
  done < <(git ls-files -z -- '*.md')
fi

status=0
for f in "${files[@]}"; do
  dir=$(dirname "$f")
  # Markdown links and images: ](target) or ](target "title"). Code blocks are not excluded, so keep
  # example links in code blocks pointing at real files, or write them without the ](...) form.
  while IFS= read -r hit; do
    line=${hit%%:*}
    target=${hit#*:}
    target=${target#](}
    target=${target%)}
    target=${target%% *}
    case "$target" in
      http://* | https://* | mailto:* | '#'* | '') continue ;;
    esac
    path=${target%%#*}
    path=${path//%20/ }
    if [ ! -e "$dir/$path" ]; then
      echo "$f:$line: broken link to $target"
      status=1
    fi
  done < <(grep -noE '\]\([^)]+\)' "$f" || true)
done

if [ "$status" -ne 0 ]; then
  echo "Link check failed." >&2
fi
exit "$status"
