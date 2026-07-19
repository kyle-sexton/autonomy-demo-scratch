#!/usr/bin/env bash
# Regression tests for tools/agent-loop/prepare-workspace.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

SCRIPT="$SCRIPT_DIR/prepare-workspace.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-loop-prepare.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

setup_repo() {
  local repo="$TMP_ROOT/repo"
  git init "$repo" >/dev/null 2>&1
  git -C "$repo" config user.email "agent-loop@test.local"
  git -C "$repo" config user.name "agent-loop"
  echo "seed" >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "chore: seed" >/dev/null
  printf '%s\n' "$repo"
}

repo_root="$(setup_repo)"
worktree_path="$TMP_ROOT/worktree"
branch="feat/agent-loop-test"

create_out="$(bash "$SCRIPT" create --repo "$repo_root" --branch "$branch" --path "$worktree_path")"
assert_contains "create prints AGENT_LOOP_WORKSPACE export" "$create_out" "AGENT_LOOP_WORKSPACE"
[[ -f "$worktree_path/README.md" ]] && pass "worktree checkout exists" || fail "worktree checkout exists" "README" "missing"

print_path_out="$(bash "$SCRIPT" create --repo "$repo_root" --branch feat/print-path --path "$TMP_ROOT/worktree-print" --print-path)"
assert_eq "--print-path stdout is path only" "$TMP_ROOT/worktree-print" "$print_path_out"

log_file="$TMP_ROOT/orchestrator.log"
: >"$log_file"
summary_out="$(bash "$SCRIPT" summary --workspace "$worktree_path" --run-log "$log_file")"
assert_contains "summary mentions workspace summary header" "$summary_out" "workspace summary"
assert_contains "orchestrator.log captured summary" "$(cat "$log_file")" "workspace summary"

[[ $FAILED -eq 0 ]] || exit 1
