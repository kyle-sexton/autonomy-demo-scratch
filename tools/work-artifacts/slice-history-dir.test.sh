#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/slice-history-dir.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/slice-history-dir.sh"
ROOT="$(git rev-parse --show-toplevel)"

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "$ROOT/tests/shell/lib.sh"

# shellcheck source=slice-history-dir.sh
source "$LIB"

assert_eq "SLICE_HISTORY_DIR_BASENAME value" "journal" "$SLICE_HISTORY_DIR_BASENAME"

# Plain assignment (no readonly) — re-sourcing must not error.
# shellcheck source=slice-history-dir.sh
source "$LIB"
assert_exit "re-source is idempotent" 0 "$?"
assert_eq "value unchanged after re-source" "journal" "$SLICE_HISTORY_DIR_BASENAME"

[[ "$FAILED" -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
