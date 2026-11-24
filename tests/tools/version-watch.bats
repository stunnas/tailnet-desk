#!/usr/bin/env bats
# Tests for the Version watch workflow's write job: the blocks between "# BEGIN pin-edit" and "# END pin-edit", and
# between "# BEGIN push-check" and "# END push-check", in .github/workflows/version-watch.yml. Each test runs them, as
# written there, on a git copy of the two real scripts (with the repo's .gitattributes, as on the runner), with
# made-up values. Run: bats tests/tools

ROOT="$BATS_TEST_DIRNAME/../.."
WORKFLOW="$ROOT/.github/workflows/version-watch.yml"
H1=$(printf 'a%.0s' {1..64}); H2=$(printf 'b%.0s' {1..64}); H3=$(printf 'c%.0s' {1..64})

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/repo/scripts/mac" "$TMP/repo/scripts/windows" "$TMP/out"
  cp "$ROOT/scripts/mac/tailnet-desk.sh" "$TMP/repo/scripts/mac/"
  cp "$ROOT/scripts/windows/tailnet-desk.psm1" "$TMP/repo/scripts/windows/"
  cp "$ROOT/.gitattributes" "$TMP/repo/"
  printf 'other\n' > "$TMP/repo/other.txt"
  git -C "$TMP/repo" init -q
  git -C "$TMP/repo" add -A
  git -C "$TMP/repo" -c user.name=t -c user.email=t@example.com commit -q -m base
  block pin-edit > "$TMP/edit.sh"
  block push-check > "$TMP/push-check.sh"
  [ "$(wc -l < "$TMP/edit.sh")" -gt 50 ]
  [ "$(wc -l < "$TMP/push-check.sh")" -gt 4 ]
  export BUMP_OUT="$TMP/out" GITHUB_OUTPUT="$TMP/out/output"
  : > "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$TMP"
}

# The workflow's block between "# BEGIN $1" and "# END $1", unindented.
block() { awk -v b="# BEGIN $1" -v e="# END $1" 'index($0, b){f=1} f{print} index($0, e){f=0}' "$WORKFLOW" | sed 's/^          //'; }

# Runs the push step's checks with BRANCH and TITLE as given.
push_check() { run env BRANCH="$1" TITLE="$2" bash "$TMP/push-check.sh"; }

# Runs the pin edit in the copy with the environment it's given.
edit() {
  run bash -c 'cd "$1" && bash "$2"' x "$TMP/repo" "$TMP/edit.sh"
}

tailscale() {
  export TAILSCALE_VERSION=1.104.5 TAILSCALE_DATE=2026-11-03 TAILSCALE_COVERED=1.104.5:2026-11-03
  export TAILSCALE_MSI_SHA256=$H1 TAILSCALE_PKG_SHA256=$H2
}

rustdesk() {
  export RUSTDESK_VERSION=1.5.5 RUSTDESK_DATE=2026-11-20 RUSTDESK_COVERED=1.5.5:2026-11-20,1.5.4:2026-11-12
  export RUSTDESK_EXE_SHA256=$H1 RUSTDESK_DMG_ARM64_SHA256=$H2 RUSTDESK_DMG_X86_64_SHA256=$H3
}

changed() { git -C "$TMP/repo" diff -U0 -- "$1" | grep -E '^\+[^+]' | sed 's/^+//'; }

@test "bumps Tailscale's version, hashes and release dates on both platforms, and nothing else" {
  tailscale
  edit
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/repo" diff --name-only | sort | tr '\n' ' ')" = 'scripts/mac/tailnet-desk.sh scripts/windows/tailnet-desk.psm1 ' ]
  mac=$(changed scripts/mac/tailnet-desk.sh)
  [ "$(wc -l <<< "$mac")" -eq 3 ]
  grep -qx "TD_TAILSCALE_VERSION='1.104.5'" <<< "$mac"
  grep -qx "TD_TAILSCALE_PKG_SHA256='$H2'" <<< "$mac"
  grep -q "^# Tailscale's Standalone installer from its own package server. Released 2026-11-03: the same version" <<< "$mac"
  win=$(changed scripts/windows/tailnet-desk.psm1)
  [ "$(wc -l <<< "$win")" -eq 3 ]
  grep -qx "    TailscaleVersion   = '1.104.5'" <<< "$win"
  grep -qx "    TailscaleMsiSha256 = '$H1'" <<< "$win"
  grep -q "^    # Tailscale's own Windows installer (MSI) from its package server, released 2026-11-03: " <<< "$win"
  # The Windows file keeps its CRLF line endings on every line.
  [ "$(grep -c $'\r$' "$TMP/repo/scripts/windows/tailnet-desk.psm1")" -eq "$(wc -l < "$TMP/repo/scripts/windows/tailnet-desk.psm1")" ]
  grep -qx 'title=chore(deps): bump Tailscale to 1.104.5' "$GITHUB_OUTPUT"
  grep -qx 'branch=bump/tailscale-1.104.5' "$GITHUB_OUTPUT"
}

@test "writes the PR body with the old and new versions and a notes link per version" {
  tailscale
  old=$(sed -n "s/^TD_TAILSCALE_VERSION='\(.*\)'/\1/p" "$ROOT/scripts/mac/tailnet-desk.sh")
  edit
  [ "$status" -eq 0 ]
  body="$BUMP_OUT/bump-body.md"
  grep -qx "## Tailscale $old to 1.104.5" "$body"
  grep -qF '| 1.104.5 | 2026-11-03 | [Release](https://github.com/tailscale/tailscale/releases/tag/v1.104.5) · [Changelog](https://tailscale.com/changelog) |' "$body"
  grep -qF 'Close and reopen this PR' "$body"
}

@test "bumps both apps in one PR, with every RustDesk version since the pin in the notes" {
  tailscale; rustdesk
  edit
  [ "$status" -eq 0 ]
  mac=$(changed scripts/mac/tailnet-desk.sh)
  [ "$(wc -l <<< "$mac")" -eq 7 ]
  grep -qx "TD_RUSTDESK_VERSION='1.5.5'" <<< "$mac"
  grep -qx "TD_RUSTDESK_SHA256_ARM64='$H2'" <<< "$mac"
  grep -qx "TD_RUSTDESK_SHA256_X86_64='$H3'" <<< "$mac"
  grep -q '^# Released 2026-11-20. Bump together with both SHA-256 values' <<< "$mac"
  win=$(changed scripts/windows/tailnet-desk.psm1)
  [ "$(wc -l <<< "$win")" -eq 6 ]
  grep -qx "    RustDeskVersion = '1.5.5'" <<< "$win"
  grep -qx "    RustDeskSha256  = '$H1'" <<< "$win"
  grep -qF '| 1.5.4 | 2026-11-12 | [Release](https://github.com/rustdesk/rustdesk/releases/tag/1.5.4) |' "$BUMP_OUT/bump-body.md"
  grep -qx 'title=chore(deps): bump RustDesk to 1.5.5 and Tailscale to 1.104.5' "$GITHUB_OUTPUT"
  grep -qx 'branch=bump/rustdesk-1.5.5-tailscale-1.104.5' "$GITHUB_OUTPUT"
}

@test "refuses any value not shaped like a version, date, list or SHA-256, before editing" {
  for bad in 'TAILSCALE_VERSION=1.104.5;x' 'TAILSCALE_VERSION=1.104' "TAILSCALE_MSI_SHA256=$(tr a-f A-F <<< "$H1")" 'TAILSCALE_PKG_SHA256=abc' \
    'TAILSCALE_DATE=2026-11-3' 'TAILSCALE_COVERED=1.104.5' "TAILSCALE_COVERED=1.104.5:2026-11-03,\$(id)"; do
    tailscale
    export "${bad?}"
    edit
    [ "$status" -eq 1 ]
    grep -q 'Refused' <<< "$output"
    [ -z "$(git -C "$TMP/repo" status --porcelain)" ]
  done
}

@test "stops when a pin line no longer matches, so a pin can't stay old by mistake" {
  tailscale
  sed -i.bak "s/^TD_TAILSCALE_PKG_SHA256=/TD_TAILSCALE_PKG_HASH=/" "$TMP/repo/scripts/mac/tailnet-desk.sh"
  rm "$TMP/repo/scripts/mac/tailnet-desk.sh.bak"
  git -C "$TMP/repo" -c user.name=t -c user.email=t@example.com commit -q -am drift
  edit
  [ "$status" -eq 1 ]
  grep -q "TD_TAILSCALE_PKG_SHA256 in scripts/mac/tailnet-desk.sh didn't take the new value" <<< "$output"
}

@test "stops when a release-date comment no longer matches" {
  tailscale
  sed -i.bak "s/from its own package server. Released/from its package server, released/" "$TMP/repo/scripts/mac/tailnet-desk.sh"
  rm "$TMP/repo/scripts/mac/tailnet-desk.sh.bak"
  git -C "$TMP/repo" -c user.name=t -c user.email=t@example.com commit -q -am drift
  edit
  [ "$status" -eq 1 ]
  grep -q "release-date comment in scripts/mac/tailnet-desk.sh didn't take the new date" <<< "$output"
}

@test "stops when anything outside the pin lines differs" {
  tailscale
  printf 'changed\n' > "$TMP/repo/other.txt"
  edit
  [ "$status" -eq 1 ]
  grep -q 'Changed a file outside the pins: other.txt' <<< "$output"
  git -C "$TMP/repo" checkout -q other.txt
  sed -i.bak "s/^TD_DIRECT_PORT=21118/TD_DIRECT_PORT=21119/" "$TMP/repo/scripts/mac/tailnet-desk.sh"
  rm "$TMP/repo/scripts/mac/tailnet-desk.sh.bak"
  edit
  [ "$status" -eq 1 ]
  grep -q 'Changed a line that is not a pin line' <<< "$output"
}

@test "passes the app that isn't due as empty values, as the workflow's env: does" {
  tailscale
  export RUSTDESK_VERSION= RUSTDESK_DATE= RUSTDESK_COVERED= RUSTDESK_EXE_SHA256= RUSTDESK_DMG_ARM64_SHA256= RUSTDESK_DMG_X86_64_SHA256=
  edit
  [ "$status" -eq 0 ]
  ! git -C "$TMP/repo" diff -U0 | grep -E '^[-+][^-+]' | grep -q RustDesk || false
  [ "$(git -C "$TMP/repo" diff -U0 | grep -c -E '^\+[^+]')" -eq 6 ]
}

@test "checks every value before editing anything, so a bad Tailscale value leaves good RustDesk values unapplied" {
  tailscale; rustdesk
  export TAILSCALE_PKG_SHA256=abc
  edit
  [ "$status" -eq 1 ]
  grep -q 'Refused the Tailscale pkg hash' <<< "$output"
  [ -z "$(git -C "$TMP/repo" status --porcelain)" ]
}

@test "stops when the edit leaves a file with more or fewer lines" {
  tailscale
  # One allowed-looking pin line more in the Windows copy and one less in the Mac copy: the line allowlist passes
  # both and the two files together still balance, so only the per-file count stops it.
  sed -i.bak "/^    RustDeskVersion = /p" "$TMP/repo/scripts/windows/tailnet-desk.psm1"
  sed -i.bak "/^TD_RUSTDESK_VERSION=/d" "$TMP/repo/scripts/mac/tailnet-desk.sh"
  rm "$TMP/repo/scripts/windows/tailnet-desk.psm1.bak" "$TMP/repo/scripts/mac/tailnet-desk.sh.bak"
  edit
  [ "$status" -eq 1 ]
  grep -q 'The edit added or removed lines in scripts/mac/tailnet-desk.sh' <<< "$output"
}

@test "the push step accepts the branch and title the pin edit makes, and nothing else" {
  tailscale
  edit
  [ "$status" -eq 0 ]
  push_check "$(sed -n 's/^branch=//p' "$GITHUB_OUTPUT")" "$(sed -n 's/^title=//p' "$GITHUB_OUTPUT")"
  [ "$status" -eq 0 ]
  : > "$GITHUB_OUTPUT"; rustdesk
  edit
  [ "$status" -eq 0 ]
  push_check "$(sed -n 's/^branch=//p' "$GITHUB_OUTPUT")" "$(sed -n 's/^title=//p' "$GITHUB_OUTPUT")"
  [ "$status" -eq 0 ]
  git -C "$TMP/repo" checkout -q .; : > "$GITHUB_OUTPUT"
  unset TAILSCALE_VERSION TAILSCALE_DATE TAILSCALE_COVERED TAILSCALE_MSI_SHA256 TAILSCALE_PKG_SHA256
  edit
  [ "$status" -eq 0 ]
  grep -qx 'branch=bump/rustdesk-1.5.5' "$GITHUB_OUTPUT"
  [ "$status" -eq 0 ]
  push_check "$(sed -n 's/^branch=//p' "$GITHUB_OUTPUT")" "$(sed -n 's/^title=//p' "$GITHUB_OUTPUT")"
  [ "$status" -eq 0 ]
  for branch in 'bump/' 'bump/-' 'bump/x;y' 'main' 'bump/tailscale-1.104.5;id' 'bump/tailscale-1.104.5-rustdesk-1.5.5'; do
    push_check "$branch" 'chore(deps): bump Tailscale to 1.104.5'
    [ "$status" -eq 1 ]
    grep -q 'Refused the branch name' <<< "$output"
  done
  for title in 'chore(deps): bump Tailscale to $(id)' 'chore(deps): bump Tailscale to 1.104' 'feat: bump Tailscale to 1.104.5'; do
    push_check bump/tailscale-1.104.5 "$title"
    [ "$status" -eq 1 ]
    grep -q 'Refused the title' <<< "$output"
  done
}

@test "stops when there is nothing to bump" {
  edit
  [ "$status" -eq 1 ]
  grep -q 'Nothing to bump' <<< "$output"
  [ -z "$(git -C "$TMP/repo" status --porcelain)" ]
}
