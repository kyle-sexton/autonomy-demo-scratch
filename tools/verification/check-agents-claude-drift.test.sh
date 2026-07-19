#!/usr/bin/env bash
# Tests for check-agents-claude-drift.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

DRIFT="$SCRIPT_DIR/check-agents-claude-drift.sh"
FAILED=0

assert_exit "--help exits 0" 0 "$(
  bash "$DRIFT" --help >/dev/null 2>&1
  echo $?
)"

out="$(bash "$DRIFT")"
assert_contains "rules count" "$out" "Rules file count:"
assert_contains "agents heading" "$out" "AGENTS top-level heading:"
assert_contains "claude heading" "$out" "CLAUDE top-level heading:"
assert_contains "includes agents" "$out" "CLAUDE includes AGENTS: yes"
assert_contains "orphan line" "$out" "Orphan rules (uncited):"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: check-agents-claude-drift.sh tests passed"
