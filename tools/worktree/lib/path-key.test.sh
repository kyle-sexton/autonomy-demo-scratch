#!/usr/bin/env bash
# Tests for tools/worktree/lib/path-key.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=path-key.sh
source "$SCRIPT_DIR/path-key.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

# --- worktree_lib_existing_ancestor ---
scratch="$TEST_TMPDIR/scratch"
mkdir -p "$scratch/existing"
resolved=$(worktree_lib_existing_ancestor "$scratch/existing/new/deep/file.txt" || true)
assert_eq "existing_ancestor walks up to existing dir" "$scratch/existing" "$resolved"

rc=0
worktree_lib_existing_ancestor "/definitely/missing/path" >/dev/null 2>&1 || rc=$?
assert_exit "existing_ancestor missing path returns non-zero" 0 "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# --- cross-worktree boundary ---
MAIN=$(worktree_test_make_repo "$TEST_TMPDIR/main-boundary")
worktree_test_add_standard_worktree "$MAIN" "wt-a"
worktree_test_add_standard_worktree "$MAIN" "wt-b"
WT_A="$MAIN/.worktrees/wt-a"
WT_B="$MAIN/.worktrees/wt-b"

rc=0
worktree_lib_check_cross_worktree_write "$WT_A/seed.txt" "$WT_A" || rc=$?
assert_exit "same worktree write allowed" 0 "$rc"

rc=0
worktree_lib_check_cross_worktree_write "$MAIN/seed.txt" "$WT_A" || rc=$?
assert_exit "cross-worktree write blocked" 2 "$rc"

rc=0
worktree_lib_check_cross_worktree_write "$WT_B/seed.txt" "$WT_A" || rc=$?
assert_exit "sibling worktree write blocked" 2 "$rc"

SCRATCH_FILE="$TEST_TMPDIR/outside.txt"
touch "$SCRATCH_FILE"
rc=0
worktree_lib_check_cross_worktree_write "$SCRATCH_FILE" "$WT_A" || rc=$?
assert_exit "non-git target allowed" 0 "$rc"

OTHER=$(worktree_test_make_repo "$TEST_TMPDIR/other-boundary")
rc=0
worktree_lib_check_cross_worktree_write "$OTHER/seed.txt" "$WT_A" || rc=$?
assert_exit "different repo allowed" 0 "$rc"

# --- worktree_lib_resolve_git_common_dir ---
common=$(worktree_lib_resolve_git_common_dir "$WT_A")
assert_contains "resolve_git_common_dir returns path" "$common" ".git"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
