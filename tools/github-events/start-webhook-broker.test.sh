#!/usr/bin/env bash
# Regression tests for tools/github-events/start-webhook-broker.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/start-webhook-broker.sh"

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# --- Case 1: --dry-run prints the plan and exits 0 -------------------------

out=$(bash "$SCRIPT" --dry-run 2>&1)
status=$?
assert_exit "dry-run exits 0" 0 "$status"
assert_contains "dry-run prints receive port" "$out" "receive port:"
assert_contains "dry-run prints subscribe port" "$out" "subscribe port:"
assert_contains "dry-run prints health url" "$out" "health url:"
assert_contains "dry-run prints completion banner" "$out" "Dry-run complete"

# --- Case 2: --help prints the script header and exits 0 -------------------

out=$(bash "$SCRIPT" --help 2>&1)
status=$?
assert_exit "help exits 0" 0 "$status"
assert_contains "help mentions Usage" "$out" "Usage:"

# --- Case 3: unknown argument exits 3 --------------------------------------

out=$(bash "$SCRIPT" --bogus 2>&1)
status=$?
assert_exit "unknown arg exits 3" 3 "$status"
assert_contains "unknown arg error mentions argument" "$out" "unknown argument"

# --- Case 4: missing build artifact exits 4 with actionable hint -----------

# Point at a nonexistent broker entry; the script should detect the missing
# file and tell the user how to build.
out=$(GITHUB_EVENTS_BROKER_ENTRY="/no/such/path/broker.js" bash "$SCRIPT" 2>&1)
status=$?
assert_exit "missing entry exits 4" 4 "$status"
assert_contains "missing entry error mentions npm run build" "$out" "npm run build"

# --- Case 5: broker liveness routed through pid::is_alive (W1-B) --------------
SCRIPT_BODY=$(cat "$SCRIPT")
if [[ "$SCRIPT_BODY" == *'pid-alive.sh'* ]]; then
  pass "case 5: start sources pid-alive.sh"
else
  fail "case 5: start sources pid-alive.sh" "present" "missing"
fi
if [[ "$SCRIPT_BODY" == *'pid::is_alive'* ]]; then
  pass "case 5: start uses pid::is_alive for broker liveness"
else
  fail "case 5: start uses pid::is_alive for broker liveness" "present" "missing"
fi
if grep -E 'kill -0' "$SCRIPT" | grep -qv '^[[:space:]]*#'; then
  fail "case 5: no bare kill -0 in start-webhook-broker body" "absent" "still present"
else
  pass "case 5: no bare kill -0 in start-webhook-broker body"
fi

[[ $FAILED -eq 0 ]] || exit 1
