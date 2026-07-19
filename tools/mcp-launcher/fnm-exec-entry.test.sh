#!/usr/bin/env bash
# Regression tests for the MCP stdio spawn path: fnm exec + launcher.js.
#
# Contract: tools/schemas/mcp-tier3-spawn.json (fnmExecPrefix, requiredEnv).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/tools/schemas/mcp-tier3-spawn.json"

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

if ! command -v fnm >/dev/null 2>&1; then
  if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
    printf 'FAIL: fnm required in CI for MCP spawn integration test\n' >&2
    exit 1
  fi
  printf 'SKIP: fnm not on PATH — run /onboard Phase 1 or bash tools/shared/node-runtime/install-fnm.sh\n'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'FAIL: jq required to load MCP spawn contract from schema\n' >&2
  exit 1
fi

if [[ ! -f "$SCHEMA_PATH" ]]; then
  printf 'FAIL: missing spawn contract schema at %s\n' "$SCHEMA_PATH" >&2
  exit 1
fi

cd "$REPO_ROOT" || exit 1

mapfile -t FNM_EXEC_ARGS < <(jq -r '.fnmExecPrefix[]' "$SCHEMA_PATH" | tr -d '\r')

run_fnm_exec_launcher() {
  while IFS='=' read -r env_key env_value; do
    export "${env_key}=${env_value}"
  done < <(jq -r '.requiredEnv | to_entries[] | "\(.key)=\(.value)"' "$SCHEMA_PATH" | tr -d '\r')
  fnm "${FNM_EXEC_ARGS[@]}" "$@"
}

# T1: fnm exec reaches launcher and npx --version
EXIT_CODE=0
run_fnm_exec_launcher --version >/dev/null 2>&1 || EXIT_CODE=$?
assert_exit "T1: fnm exec + launcher --version exits 0" 0 "$EXIT_CODE"

# T2: stdout non-empty (stdio passthrough)
OUTPUT=$(run_fnm_exec_launcher --version 2>/dev/null)
CASE_NUM=$((CASE_NUM + 1))
if [[ -n "$OUTPUT" ]]; then
  printf 'PASS: [%d] T2: fnm exec entry produced stdout (%q)\n' "$CASE_NUM" "$OUTPUT"
else
  printf 'FAIL: [%d] T2: fnm exec entry produced empty stdout\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
fi

# T3: full MCP bootstrap path stays within budget (guards double-wrap / extra
# shell hops). Gated as a hard pass/fail ONLY on CI (ubuntu-latest — the
# authoritative correctness gate, where forks are ~10x cheaper and wall-clock is
# deterministic). Local Git Bash under JOBS=8 MSYS2 contention spikes seconds
# past any tight budget (measured 4012ms on a loaded box), so locally the timing
# is advisory — printed for quiet-box regression visibility, not gated.
# $EPOCHREALTIME replaces two `python -c` timestamp forks.
BOOTSTRAP_BUDGET_MS=3000
EXIT_CODE=0
start=$EPOCHREALTIME
run_fnm_exec_launcher --version >/dev/null 2>&1 || EXIT_CODE=$?
end=$EPOCHREALTIME
ELAPSED_MS=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%d", (e - s) * 1000}')
if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
  CASE_NUM=$((CASE_NUM + 1))
  if [[ "${EXIT_CODE:-0}" -eq 0 && "$ELAPSED_MS" -le "$BOOTSTRAP_BUDGET_MS" ]]; then
    printf 'PASS: [%d] T3: fnm exec bootstrap %d ms (budget %d ms)\n' "$CASE_NUM" "$ELAPSED_MS" "$BOOTSTRAP_BUDGET_MS"
  else
    printf 'FAIL: [%d] T3: fnm exec bootstrap %d ms or exit %s (budget %d ms)\n' \
      "$CASE_NUM" "$ELAPSED_MS" "${EXIT_CODE:-0}" "$BOOTSTRAP_BUDGET_MS" >&2
    FAILED=$((FAILED + 1))
  fi
else
  printf 'INFO: T3 fnm exec bootstrap %d ms (advisory — wall-clock not gated under local JOBS=8 contention)\n' "$ELAPSED_MS"
fi

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d test(s) passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d of %d test(s) failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
