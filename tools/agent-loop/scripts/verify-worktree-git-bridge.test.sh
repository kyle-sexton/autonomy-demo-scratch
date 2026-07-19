#!/usr/bin/env bash
# shellcheck source=../../tests/shell/lib.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$AGENT_LOOP_ROOT/../.." && pwd)
FAILED=0
# shellcheck disable=SC1091
source "$REPO_ROOT/tests/shell/lib.sh"

assert_file_exists "verify-worktree-git-bridge.sh exists" "$SCRIPT_DIR/verify-worktree-git-bridge.sh"
assert_file_exists "verify-worktree-git-bridge.ts source exists" \
  "$AGENT_LOOP_ROOT/src/verify-worktree-git-bridge.ts"

help_output=$(bash "$SCRIPT_DIR/verify-worktree-git-bridge.sh" --help 2>&1)
help_rc=$?
assert_exit "verify-worktree-git-bridge --help exits 0" 0 "$help_rc"
assert_contains "verify-worktree-git-bridge --help shows usage" "$help_output" \
  "Usage: verify-worktree-git-bridge.sh"

pass "verify-worktree-git-bridge script tests"

[[ $FAILED -eq 0 ]] || exit 1
