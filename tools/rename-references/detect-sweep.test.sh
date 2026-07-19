#!/usr/bin/env bash
# Tests for detect-sweep.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

SWEEP="$SCRIPT_DIR/detect-sweep.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILED=0

assert_exit "--help exits 0" 0 "$(
  bash "$SWEEP" --help >/dev/null 2>&1
  echo $?
)"

git init "$TEST_TMPDIR/repo" >/dev/null 2>&1
git -C "$TEST_TMPDIR/repo" config user.email "t@example.com"
git -C "$TEST_TMPDIR/repo" config user.name "Test"
mkdir -p "$TEST_TMPDIR/repo/docs"
printf 'Use /fooskill for workflow\n' >"$TEST_TMPDIR/repo/docs/note.md"
git -C "$TEST_TMPDIR/repo" add docs/note.md
git -C "$TEST_TMPDIR/repo" commit -m "init" >/dev/null

out="$(GIT_DIR="$TEST_TMPDIR/repo/.git" GIT_WORK_TREE="$TEST_TMPDIR/repo" bash -c \
  "cd '$TEST_TMPDIR/repo' && REGISTRY='$SCRIPT_DIR/patterns.registry.tsv' bash '$SWEEP' --old /fooskill --mode blast")"
assert_contains "mode blast" "$out" "Mode: blast"
assert_contains "slash match" "$out" "Match: docs/note.md"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: detect-sweep.sh tests passed"
