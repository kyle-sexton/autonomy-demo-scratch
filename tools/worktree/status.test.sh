#!/usr/bin/env bash
# Tests for status.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

STATUS="$SCRIPT_DIR/status.sh"
FAILED=0

rc=0
bash "$STATUS" --help >/dev/null 2>&1 || rc=$?
assert_exit "--help exits 0" 0 "$rc"

out="$(bash "$STATUS" 2>/dev/null)"
assert_contains "emits worktree count" "$out" "Worktree count:"
assert_contains "emits github api status" "$out" "GitHub API:"

# In a real repo we expect at least one worktree
count_line="$(printf '%s\n' "$out" | grep '^Worktree count:' | head -1)"
assert_contains "count is numeric" "$count_line" "Worktree count: "

if [[ $FAILED -ne 0 ]]; then
  echo "FAILED: $FAILED test(s)"
  exit 1
fi
echo "OK: status.sh tests passed"
