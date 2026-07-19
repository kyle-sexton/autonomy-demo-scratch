#!/usr/bin/env bash
# Tests for tools/worktree/setup-worktree.sh — all pipelines via BOOTSTRAP_SH stub.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

SETUP="$SCRIPT_DIR/setup-worktree.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

rc=0
bash "$SETUP" --help >/dev/null 2>&1 || rc=$?
assert_exit "--help exits 0" 0 "$rc"

rc=0
bash "$SETUP" 2>/dev/null || rc=$?
assert_exit "missing pipeline exits 2" 2 "$rc"

rc=0
bash "$SETUP" --pipeline bogus 2>/dev/null || rc=$?
assert_exit "unknown pipeline exits 2" 2 "$rc"

# --- cursor pipeline ---
base="$TEST_TMPDIR/cursor"
mkdir -p "$base/wt" "$base/main/.claude"
marker="$base/bootstrap.log"
worktree_test_install_bootstrap_stub "$base/wt" "$marker"
printf '.claude/settings.local.json\n' >"$base/main/.worktreeinclude"
printf '{}' >"$base/main/.claude/settings.local.json"
export BOOTSTRAP_SH="$base/wt/tools/bootstrap.sh"
(
  cd "$base/wt" || exit 1
  export ROOT_WORKTREE_PATH="$base/main"
  bash "$SETUP" --pipeline cursor >/dev/null 2>&1
)
assert_file_exists "cursor pipeline ran bootstrap" "$marker"

# --- claude-session-start-main ---
main_repo=$(worktree_test_make_repo "$TEST_TMPDIR/session-main")
marker_main="$TEST_TMPDIR/session-main-marker"
worktree_test_install_bootstrap_stub "$main_repo" "$marker_main"
export BOOTSTRAP_SH="$main_repo/tools/bootstrap.sh"
out_main=$(bash "$SETUP" --pipeline claude-session-start-main --cwd "$main_repo" --main-root "$main_repo" 2>/dev/null)
assert_file_exists "session-start-main ran bootstrap" "$marker_main"
assert_contains "session-start-main bootstrap captured --quiet" "$(cat "$marker_main")" "--quiet"
assert_silent "session-start-main no ctx when bootstrap quiet" "$out_main"

# --- claude-session-start-worktree ---
session_repo=$(worktree_test_make_repo "$TEST_TMPDIR/session-wt")
worktree_test_add_standard_worktree "$session_repo" "feat"
WT="$session_repo/.worktrees/feat"
marker_wt="$TEST_TMPDIR/session-wt-marker"
worktree_test_install_bootstrap_stub "$session_repo" "$marker_wt"
export BOOTSTRAP_SH="$session_repo/tools/bootstrap.sh"
out_wt=$(bash "$SETUP" \
  --pipeline claude-session-start-worktree \
  --cwd "$WT" \
  --main-root "$session_repo" \
  --worktree-root "$WT" 2>/dev/null)
# Provisioning (dotnet restore + bootstrap) is now backgrounded for fast
# SessionStart — poll for the bootstrap marker instead of asserting it synchronously.
for _ in $(seq 1 50); do
  [[ -f "$marker_wt" ]] && break
  sleep 0.1
done
assert_file_exists "session-start-worktree ran bootstrap (backgrounded)" "$marker_wt"
assert_contains "session-start-worktree emits banner" "$out_wt" "Worktree auto-setup:"
assert_contains "session-start-worktree fetch action" "$out_wt" "Backgrounded origin/main fetch"
assert_contains "session-start-worktree provisioning action" "$out_wt" "Backgrounded .NET restore"

# --- agent-loop-post-create ---
loop_repo=$(worktree_test_make_repo "$TEST_TMPDIR/loop")
loop_wt="$TEST_TMPDIR/loop-wt"
git -C "$loop_repo" worktree add "$loop_wt" -b loop-branch >/dev/null 2>&1
printf '.claude/settings.local.json\n' >"$loop_repo/.worktreeinclude"
mkdir -p "$loop_repo/.claude"
printf '{"env":{"X":1}}' >"$loop_repo/.claude/settings.local.json"
marker_loop="$TEST_TMPDIR/loop-marker"
worktree_test_install_bootstrap_stub "$loop_repo" "$marker_loop"
export BOOTSTRAP_SH="$loop_repo/tools/bootstrap.sh"
bash "$SETUP" \
  --pipeline agent-loop-post-create \
  --main-root "$loop_repo" \
  --worktree-root "$loop_wt" >/dev/null 2>&1
assert_file_exists "agent-loop-post-create ran bootstrap" "$marker_loop"
assert_file_exists "agent-loop-post-create copied include" "$loop_wt/.claude/settings.local.json"

# --- claude-session-start orchestrator ---
orch_repo=$(worktree_test_make_repo "$TEST_TMPDIR/orch")
worktree_test_add_standard_worktree "$orch_repo" "orch-wt"
ORCH_WT="$orch_repo/.worktrees/orch-wt"
marker_orch="$TEST_TMPDIR/orch-marker"
worktree_test_install_bootstrap_stub "$orch_repo" "$marker_orch"
export BOOTSTRAP_SH="$orch_repo/tools/bootstrap.sh"
out_orch=$(bash "$SETUP" --pipeline claude-session-start --cwd "$ORCH_WT" 2>/dev/null)
assert_file_exists "claude-session-start ran bootstrap" "$marker_orch"
assert_contains "claude-session-start emits worktree banner" "$out_orch" "Worktree auto-setup:"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
