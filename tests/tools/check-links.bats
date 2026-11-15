#!/usr/bin/env bats
# Tests for tools/check-links.sh. Run: bats tests/tools

setup() {
  CHECK="$BATS_TEST_DIRNAME/../../tools/check-links.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/repo"
  printf '# Outside\n' > "$TMP/outside.md"
  git -C "$TMP/repo" init -q
  cd "$TMP/repo"
  mkdir -p docs/images
  touch docs/images/shot.png
  printf '# Other\n\n## Step 1: Join Tailscale\n\n## The controller'"'"'s address\n' > docs/other.md
}

teardown() {
  rm -rf "$TMP"
}

@test "passes existing links, images, anchors and web links" {
  printf '%s\n' '# Top' '[other](other.md) ![shot](images/shot.png "title") [step](other.md#step-1-join-tailscale)' \
    "[addr](other.md#the-controllers-address) [web](https://example.com) [here](#top)" > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 0 ]
}

@test "fails a missing image" {
  printf '%s\n' '![shot](images/missing.png)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"broken link to images/missing.png"* ]]
}

@test "fails a missing page and reports the line" {
  printf 'ok\n[gone](gone.md)\n' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"guide.md:2:"* ]]
}

@test "fails an anchor with no matching heading, in another file or the same one" {
  printf '%s\n' '[x](other.md#step-2)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"no heading for #step-2"* ]]
  printf '%s\n' '# Top' '[x](#bottom)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
}

@test "fails a link that leaves the repository" {
  printf '%s\n' '[x](../../outside.md)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"outside the repository"* ]]
}

@test "fails a link through a symlinked folder partway along the path" {
  mkdir -p "$TMP/elsewhere" && printf '# Far\n' > "$TMP/elsewhere/far.md"
  ln -s ../../elsewhere docs/via
  printf '%s\n' '[x](via/far.md)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"outside the repository"* ]]
}

@test "numbers repeated headings the way GitHub does" {
  printf '%s\n' '# Steps' '## Check' '## Check' '[first](#check) [second](#check-1)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 0 ]
  printf '%s\n' '# Steps' '## Check' '[third](#check-2)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
}

@test "decodes %20 in a link to a file name with a space" {
  printf '# Spaced\n' > 'docs/two words.md'
  printf '%s\n' '[x](two%20words.md)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 0 ]
}

@test "fails when a named file doesn't exist" {
  run "$CHECK" docs/missing.md
  [ "$status" -eq 2 ]
}

@test "without arguments, checks every tracked Markdown file" {
  printf '%s\n' '[gone](gone.md)' > docs/guide.md
  git add -A
  run "$CHECK"
  [ "$status" -eq 1 ]
}

@test "fails a link to a symlink, which could lead outside the repository" {
  ln -s ../../outside.md docs/sneaky.md
  printf '%s\n' '[x](sneaky.md#outside)' > docs/guide.md
  run "$CHECK" docs/guide.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
}

@test "without arguments, skips tests/fixtures/ and tracked symlinks" {
  mkdir -p tests/fixtures
  printf '%s\n' '[gone](gone.md)' > tests/fixtures/broken.md
  printf '%s\n' '[gone](gone.md)' > "$TMP/bad.md"
  ln -s ../bad.md linked.md
  git add -A
  run "$CHECK"
  [ "$status" -eq 0 ]
}
