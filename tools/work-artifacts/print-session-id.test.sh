#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/print-session-id.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/print-session-id.sh"

FAILED=0
CASE_NUM=0

# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel | tr -d '\r')/tests/shell/lib.sh"

out=$(bash "$SUT" --help)
assert_exit "--help exits 0" 0 "$?"
assert_contains "--help prints usage" "$out" "print-session-id.sh"

out=$(CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555" bash "$SUT")
assert_eq "prints the env var value when set" "11111111-2222-3333-4444-555555555555" "$out"

out=$(env -u CLAUDE_CODE_SESSION_ID bash "$SUT")
assert_eq "prints unknown when unset" "unknown" "$out"

out=$(CLAUDE_CODE_SESSION_ID="" bash "$SUT")
assert_eq "prints unknown when empty" "unknown" "$out"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
