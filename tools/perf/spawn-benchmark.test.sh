#!/usr/bin/env bash
# Regression tests for tools/perf/spawn-benchmark.sh.
#
# Contract-level only (flag parsing, JSON shape, error exits) — the timing
# numbers themselves are machine-dependent and deliberately unasserted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/spawn-benchmark.sh"

FAILED=0
CASE_NUM=0

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Case 1: --help exits 0 and prints usage.
out=$(bash "$SUT" --help 2>&1)
rc=$?
assert_exit "help exits 0" 0 "$rc"
assert_contains "help mentions usage" "$out" "Usage:"

# Case 2: --json emits one parseable object with per-kind p50/p95.
out=$(bash "$SUT" --json --iterations 3 2>&1)
rc=$?
assert_exit "json run exits 0" 0 "$rc"
if command -v jq >/dev/null 2>&1; then
  p50=$(jq -r '.results.bash.ms_p50' <<<"$out" 2>/dev/null)
  if [[ "$p50" =~ ^[0-9]+$ ]]; then
    pass "json has numeric results.bash.ms_p50"
  else
    fail "json has numeric results.bash.ms_p50" "integer" "${p50:-<unparseable>}"
  fi
else
  skip_case "jq unavailable — JSON shape unchecked"
fi

# Case 3: unknown flag exits 2.
bash "$SUT" --nonsense >/dev/null 2>&1
assert_exit "unknown flag exits 2" 2 "$?"

# Case 4: --iterations below minimum exits 2.
bash "$SUT" --iterations 1 >/dev/null 2>&1
assert_exit "iterations < 3 exits 2" 2 "$?"

[[ $FAILED -eq 0 ]] || exit 1
echo "All $CASE_NUM cases passed."
