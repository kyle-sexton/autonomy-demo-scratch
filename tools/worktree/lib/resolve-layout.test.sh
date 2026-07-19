#!/usr/bin/env bash
# Tests for tools/worktree/lib/resolve-layout.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=resolve-layout.sh
source "$SCRIPT_DIR/resolve-layout.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

# --- standard clone layout ---
STD_MAIN=$(worktree_test_make_repo "$TEST_TMPDIR/std-main")
worktree_lib_resolve_worktree_path "$STD_MAIN" "feat-login"
assert_contains "standard layout worktree path" "$WORKTREE_PATH" ".worktrees/feat-login"
assert_contains "standard layout git context" "$GIT_CONTEXT" "std-main"
assert_contains "standard layout repo root" "$REPO_ROOT" "std-main"

worktree_test_add_standard_worktree "$STD_MAIN" "existing"
REGISTERED_PATH=$(git -C "$STD_MAIN" worktree list --porcelain 2>/dev/null | tr -d '\r' | awk '/^worktree / && /existing$/ { sub(/^worktree /,""); print; exit }')
assert_eq "registered worktree detected" "0" "$(
  worktree_lib_worktree_registered "$STD_MAIN" "$REGISTERED_PATH" && echo 0 || echo 1
)"

assert_eq "unregistered path not detected" "1" "$(
  worktree_lib_worktree_registered "$STD_MAIN" "$STD_MAIN/.worktrees/missing" && echo 0 || echo 1
)"

# --- bare-clone hub layout ---
SRC=$(worktree_test_make_repo "$TEST_TMPDIR/src-hub")
HUB=$(worktree_test_make_bare_hub "$SRC" "$TEST_TMPDIR/hub-layout")
worktree_lib_resolve_worktree_path "$HUB/main" "alpha"
assert_contains "bare hub worktree path" "$WORKTREE_PATH" "/alpha"
assert_contains "bare hub git context is session cwd" "$GIT_CONTEXT" "main"
assert_contains "bare hub root set" "$HUB_ROOT" "hub-layout"

# --- include source resolution ---
mkdir -p "$STD_MAIN/.claude"
printf '.claude/settings.local.json\n' >"$STD_MAIN/.worktreeinclude"
printf '{}' >"$STD_MAIN/.claude/settings.local.json"
src=$(worktree_lib_resolve_include_source "$STD_MAIN" "$STD_MAIN/.worktrees/new" "" "$STD_MAIN")
assert_eq "standard clone include source is repo root" "$STD_MAIN" "$src"

# --- claude session detection ---
mapfile -t _main_session < <(worktree_lib_detect_claude_session "$STD_MAIN")
assert_eq "main repo session not worktree" "false" "${_main_session[2]}"

worktree_test_add_standard_worktree "$STD_MAIN" "session-detect"
WT_SESSION="$STD_MAIN/.worktrees/session-detect"
mapfile -t _wt_session < <(worktree_lib_detect_claude_session "$WT_SESSION")
assert_eq "linked worktree session detected" "true" "${_wt_session[2]}"
assert_contains "worktree root resolved" "${_wt_session[3]}" "session-detect"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
