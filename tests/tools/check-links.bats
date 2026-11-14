#!/usr/bin/env bats
# Tests for tools/check-links.sh. Run: bats tests/tools

setup() {
  CHECK="$BATS_TEST_DIRNAME/../../tools/check-links.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/docs/images"
  touch "$TMP/docs/images/shot.png" "$TMP/docs/other.md"
}

teardown() {
  rm -rf "$TMP"
}

@test "passes existing links, images, anchors and web links" {
  printf '%s\n' '[other](other.md) ![shot](images/shot.png "title") [part](other.md#step-1) [web](https://example.com) [here](#top)' \
    > "$TMP/docs/guide.md"
  run "$CHECK" "$TMP/docs/guide.md"
  [ "$status" -eq 0 ]
}

@test "fails a missing image" {
  printf '%s\n' '![shot](images/missing.png)' > "$TMP/docs/guide.md"
  run "$CHECK" "$TMP/docs/guide.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"broken link to images/missing.png"* ]]
}

@test "fails a missing page and reports the line" {
  printf 'ok\n[gone](gone.md)\n' > "$TMP/docs/guide.md"
  run "$CHECK" "$TMP/docs/guide.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"guide.md:2:"* ]]
}
