#!/usr/bin/env bash
# Tests for tools/worktree/lib/scan-orphan-worktrees.sh
# Ports orphan-count regressions from .claude/hooks/worktree-setup.test.sh cases 9-10.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=scan-orphan-worktrees.sh
source "$SCRIPT_DIR/scan-orphan-worktrees.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

# Case 9: bare-hub — one genuine orphan, siblings registered.
SRC9=$(worktree_test_make_repo "$TEST_TMPDIR/src9")
HUB9=$(worktree_test_make_bare_hub "$SRC9" "$TEST_TMPDIR/hub9")
git -C "$HUB9/.bare" worktree add "$HUB9/alpha" -b alpha >/dev/null 2>&1
git -C "$HUB9/.bare" worktree add "$HUB9/beta" -b beta >/dev/null 2>&1
mkdir -p "$HUB9/orphan-gamma"
COMMON9=$(git -C "$HUB9/alpha" rev-parse --git-common-dir | tr -d '\r')
COUNT9=$(worktree_lib_count_orphan_worktrees "$HUB9/main" "$COMMON9" true)
assert_eq "bare hub counts exactly one orphan sibling" "1" "$COUNT9"

# Case 10: prefix-collision — orphan feat vs registered feature.
SRC10=$(worktree_test_make_repo "$TEST_TMPDIR/src10")
HUB10=$(worktree_test_make_bare_hub "$SRC10" "$TEST_TMPDIR/hub10")
git -C "$HUB10/.bare" worktree add "$HUB10/feature" -b feature >/dev/null 2>&1
mkdir -p "$HUB10/feat"
COMMON10=$(git -C "$HUB10/feature" rev-parse --git-common-dir | tr -d '\r')
COUNT10=$(worktree_lib_count_orphan_worktrees "$HUB10/main" "$COMMON10" true)
assert_eq "prefix substring orphan feat not dropped" "1" "$COUNT10"

# Standard .worktrees/ orphan scan.
STD=$(worktree_test_make_repo "$TEST_TMPDIR/std-orphan")
mkdir -p "$STD/.worktrees/orphan-dir"
COUNT_STD=$(worktree_lib_count_orphan_worktrees "$STD" "$STD/.git" false)
assert_eq "standard layout orphan under .worktrees counted" "1" "$COUNT_STD"

worktree_test_add_standard_worktree "$STD" "registered"
COUNT_STD2=$(worktree_lib_count_orphan_worktrees "$STD" "$STD/.git" false)
assert_eq "registered worktree not counted as orphan" "1" "$COUNT_STD2"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
