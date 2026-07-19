#!/usr/bin/env bash
# Tests for tools/worktree/setup-cursor-worktree.sh (thin adapter → setup-worktree.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../tests/shell/lib.sh
source "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)/tests/shell/lib.sh"

ADAPTER="$SCRIPT_DIR/setup-cursor-worktree.sh"
ORCHESTRATOR="$SCRIPT_DIR/setup-worktree.sh"

CASE_NUM=0
FAILED=0

# Adapter delegates to orchestrator (subprocess, not source).
OUT=$(bash "$ADAPTER" --help 2>&1)
assert_contains "adapter --help delegates to setup-worktree" "$OUT" "setup-worktree.sh"

OUT=$(ROOT_WORKTREE_PATH="$(mktemp -d)" bash "$ORCHESTRATOR" --pipeline cursor 2>&1 || true)
assert_contains "cursor pipeline runs via orchestrator" "$OUT" "pipeline cursor"

# --- .cursor/worktrees.json contract (Cursor worktree auto-setup) ---
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
WORKTREES_JSON="$REPO_ROOT/.cursor/worktrees.json"

assert_file_exists "worktrees.json exists" "$WORKTREES_JSON"
assert_file_exists "setup script exists" "$ADAPTER"

if command -v jq >/dev/null 2>&1; then
  unix_ref="$(jq -r '."setup-worktree-unix" // empty' "$WORKTREES_JSON")"
  resolved_unix="$(cd "$(dirname "$WORKTREES_JSON")" && realpath "$unix_ref" 2>/dev/null || echo "")"
  if [[ -n "$resolved_unix" ]] && [[ -f "$resolved_unix" ]] && [[ "$resolved_unix" -ef "$ADAPTER" ]]; then
    pass "setup-worktree-unix points at setup script"
  else
    fail "setup-worktree-unix points at setup script" "$ADAPTER" "${resolved_unix:-missing}"
  fi

  windows_cmd="$(jq -r '."setup-worktree-windows"[0] // empty' "$WORKTREES_JSON")"
  assert_eq "setup-worktree-windows invokes setup script" \
    "bash tools/worktree/setup-cursor-worktree.sh" \
    "$windows_cmd"
else
  skip_case "jq unavailable — skipping worktrees.json path contract"
fi

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
