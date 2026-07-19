#!/usr/bin/env bash
# Tests for tools/worktree/enforce-boundary.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

ENFORCE="$SCRIPT_DIR/enforce-boundary.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

rc=0
bash "$ENFORCE" --help >/dev/null 2>&1 || rc=$?
assert_exit "--help exits 0" 0 "$rc"

rc=0
bash "$ENFORCE" 2>/dev/null || rc=$?
assert_exit "missing args fail-open exit 0" 0 "$rc"

MAIN=$(worktree_test_make_repo "$TEST_TMPDIR/main")
worktree_test_add_standard_worktree "$MAIN" "wt-a"
worktree_test_add_standard_worktree "$MAIN" "wt-b"
WT_A="$MAIN/.worktrees/wt-a"
WT_B="$MAIN/.worktrees/wt-b"

rc=0
bash "$ENFORCE" --cwd "$WT_A" --file-path "$WT_A/seed.txt" 2>/dev/null || rc=$?
assert_exit "same worktree allowed" 0 "$rc"

rc=0
bash "$ENFORCE" --cwd "$WT_A" --file-path "$MAIN/seed.txt" 2>/dev/null || rc=$?
assert_exit "cross worktree to main blocked" 2 "$rc"

rc=0
diag=$(bash "$ENFORCE" --cwd "$WT_A" --file-path "$WT_B/seed.txt" --emit-diagnostic 2>&1) || rc=$?
assert_exit "sibling worktree blocked" 2 "$rc"
assert_contains "diagnostic mentions BLOCKED" "$diag" "BLOCKED"

SCRATCH="$TEST_TMPDIR/scratch.txt"
touch "$SCRATCH"
rc=0
bash "$ENFORCE" --cwd "$WT_A" --file-path "$SCRATCH" 2>/dev/null || rc=$?
assert_exit "non-git path allowed" 0 "$rc"

OTHER=$(worktree_test_make_repo "$TEST_TMPDIR/other")
rc=0
bash "$ENFORCE" --cwd "$WT_A" --file-path "$OTHER/seed.txt" 2>/dev/null || rc=$?
assert_exit "different repo allowed" 0 "$rc"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
