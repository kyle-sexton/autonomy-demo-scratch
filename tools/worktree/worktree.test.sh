#!/usr/bin/env bash
# Tests for tools/worktree/worktree.sh dispatcher.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

DISPATCHER="$SCRIPT_DIR/worktree.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

OUT=$(bash "$DISPATCHER" --help 2>&1)
assert_contains "help lists setup subcommand" "$OUT" "setup"
assert_contains "help lists create subcommand" "$OUT" "create"
assert_contains "help lists list-orphans subcommand" "$OUT" "list-orphans"

OUT=$(bash "$DISPATCHER" setup --help 2>&1)
assert_contains "setup delegates to setup-worktree" "$OUT" "setup-worktree.sh"

OUT=$(bash "$DISPATCHER" create --help 2>&1)
assert_contains "create delegates to create-worktree" "$OUT" "create-worktree.sh"

rc=0
bash "$DISPATCHER" bogus 2>/dev/null || rc=$?
assert_exit "unknown subcommand exits 2" 2 "$rc"

# --- list-orphans ---
ORPHAN_REPO=$(worktree_test_make_repo "$TEST_TMPDIR/orphan-repo")
mkdir -p "$ORPHAN_REPO/.worktrees/stale-dir"
LIST_OUT=$(bash "$DISPATCHER" list-orphans "$ORPHAN_REPO" 2>/dev/null)
assert_contains "list-orphans reports count" "$LIST_OUT" "1 orphan worktree dir(s)"

worktree_test_add_standard_worktree "$ORPHAN_REPO" "live"
LIST_OUT2=$(bash "$DISPATCHER" list-orphans "$ORPHAN_REPO" 2>/dev/null)
assert_contains "list-orphans still counts disk-only orphan" "$LIST_OUT2" "1 orphan worktree dir(s)"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
