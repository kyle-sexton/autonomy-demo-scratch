#!/usr/bin/env bash
# Regression tests for tools/shared/process-management/pid-alive.sh.
#
# Source the lib (pure function, no side effects) and drive pid::is_alive
# against known-alive / known-dead / malformed inputs.
#
# Run: bash tools/shared/process-management/pid-alive.test.sh
# Or:  bash tools/run-shell-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/pid-alive.sh"

FAILED=0
CASE_NUM=0
LIVE_PIDS=()
cleanup() {
  local p
  for p in "${LIVE_PIDS[@]}"; do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

# shellcheck source=../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# shellcheck source=./pid-alive.sh
source "$LIB"

# --- Case: current shell PID is alive -----------------------------------------
pid::is_alive "$$"
assert_exit "current shell PID is alive" 0 "$?"

# --- Case: freshly backgrounded process is alive ------------------------------
sleep 30 &
LIVE_PID=$!
LIVE_PIDS+=("$LIVE_PID")
pid::is_alive "$LIVE_PID"
assert_exit "backgrounded process is alive" 0 "$?"

# --- Case: high unallocated PID is not alive ----------------------------------
pid::is_alive 999999
assert_exit "unallocated PID not alive" 1 "$?"

# --- Case: non-numeric input is not alive (never reaches kill/tasklist) --------
pid::is_alive "abc"
assert_exit "non-numeric PID not alive" 1 "$?"

# --- Case: negative '-1' is rejected by the numeric guard ---------------------
# Critical: bare `kill -0 -1` is "all processes" on POSIX; the guard must stop
# it reaching kill. Non-numeric guard rejects the leading '-'.
pid::is_alive "-1"
assert_exit "negative PID rejected (no kill -0 -1)" 1 "$?"

# --- Case: empty input is not alive -------------------------------------------
pid::is_alive ""
assert_exit "empty PID not alive" 1 "$?"

# --- Windows tasklist fallback (native-winpid path) ---------------------------
# The fallback fires only when kill -0 FAILS on a live process, which requires a
# native Windows PID outside the MSYS pid namespace. Test fixtures spawn MSYS
# pids (kill -0 succeeds), so this branch is unobservable in-test. Exercised by
# the real-world repro 2026-05-29 (kill -0 false on 5 live broker winpids;
# tasklist confirmed alive).
if [[ "${OS:-}" == "Windows_NT" ]] && command -v tasklist >/dev/null 2>&1; then
  # Smoke: tasklist accepts the escaped-flag form the lib uses (no error exit).
  tasklist //FI "PID eq $$" //NH //FO CSV >/dev/null 2>&1
  assert_exit "Windows: tasklist accepts lib's escaped-flag form" 0 "$?"
else
  skip_case "Windows tasklist fallback: native-winpid path not reachable off Windows"
fi

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
