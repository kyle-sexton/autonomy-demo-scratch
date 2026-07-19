#!/usr/bin/env bash
# Tests for detect-pair.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

DETECT="$SCRIPT_DIR/detect-pair.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILED=0

rc=0
bash "$DETECT" --help >/dev/null 2>&1 || rc=$?
assert_exit "--help exits 0" 0 "$rc"

git init "$TEST_TMPDIR/repo" >/dev/null 2>&1
git -C "$TEST_TMPDIR/repo" config user.email "t@example.com"
git -C "$TEST_TMPDIR/repo" config user.name "Test"
echo old >"$TEST_TMPDIR/repo/old.txt"
git -C "$TEST_TMPDIR/repo" add old.txt
git -C "$TEST_TMPDIR/repo" commit -m "init" >/dev/null
git -C "$TEST_TMPDIR/repo" mv old.txt new.txt

out="$(GIT_DIR="$TEST_TMPDIR/repo/.git" GIT_WORK_TREE="$TEST_TMPDIR/repo" bash -c "cd '$TEST_TMPDIR/repo' && bash '$DETECT'")"
assert_contains "detects renamed file" "$out" "old.txt -> new.txt"
assert_contains "emits pair count" "$out" "Rename pair count:"

out="$(bash "$DETECT" 2>/dev/null)"
assert_contains "main repo emits pair count" "$out" "Rename pair count:"

if [[ $FAILED -ne 0 ]]; then
  echo "FAILED: $FAILED test(s)"
  exit 1
fi
echo "OK: detect-pair.sh tests passed"
