#!/usr/bin/env bash
# Tests for create-worktree.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

CREATE="$SCRIPT_DIR/create-worktree.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

rc=0
bash "$CREATE" --help >/dev/null 2>&1 || rc=$?
assert_exit "--help exits 0" 0 "$rc"

rc=0
bash "$CREATE" 2>/dev/null || rc=$?
assert_exit "missing args exits non-zero" 0 "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

rc=0
bash "$CREATE" --cwd "$TEST_TMPDIR" --branch feat/x 2>/dev/null || rc=$?
assert_exit "explicit mode requires worktree-path" 0 "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# --- standard layout integration ---
MAIN=$(worktree_test_make_repo "$TEST_TMPDIR/main")
PATH_OUT=$(bash "$CREATE" --name feat/login --cwd "$MAIN" --print-path 2>/dev/null)
assert_contains "standard create prints worktree path" "$PATH_OUT" ".worktrees/feat-login"
assert_file_exists "standard worktree materialized" "$MAIN/.worktrees/feat-login/seed.txt"
BRANCH=$(git -C "$MAIN/.worktrees/feat-login" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r')
assert_eq "branch derived from name" "feat/login" "$BRANCH"

# --- idempotent reuse ---
PATH_REUSE=$(bash "$CREATE" --name feat/login --cwd "$MAIN" --print-path 2>/dev/null)
assert_eq "idempotent reuse same path" "$PATH_OUT" "$PATH_REUSE"

# --- explicit mode (agent-loop) ---
ISO=$(worktree_test_make_repo "$TEST_TMPDIR/iso")
EXT_PATH="$TEST_TMPDIR/external-wt"
EXPLICIT_OUT=$(bash "$CREATE" \
  --cwd "$ISO" \
  --branch feat/explicit \
  --worktree-path "$EXT_PATH" \
  --print-path 2>/dev/null)
assert_eq "explicit mode prints requested path" "$EXT_PATH" "$EXPLICIT_OUT"
assert_file_exists "explicit worktree checkout exists" "$EXT_PATH/seed.txt"

# --- skip-copy ---
MAIN2=$(worktree_test_make_repo "$TEST_TMPDIR/main2")
printf '.claude/settings.local.json\n' >"$MAIN2/.worktreeinclude"
mkdir -p "$MAIN2/.claude"
printf '{"token":"main"}' >"$MAIN2/.claude/settings.local.json"
bash "$CREATE" --name chore/nocopy --cwd "$MAIN2" --skip-copy >/dev/null 2>&1
if [[ -f "$MAIN2/.worktrees/chore-nocopy/.claude/settings.local.json" ]]; then
  fail "skip-copy omits include" "absent" "present"
else
  pass "skip-copy omits include"
fi

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
