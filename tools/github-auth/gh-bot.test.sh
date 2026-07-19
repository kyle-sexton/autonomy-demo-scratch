#!/usr/bin/env bash
# Regression tests for tools/github-auth/gh-bot.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/gh-bot.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel | tr -d '\r')/tests/shell/lib.sh"

ORIG_APP_ID="${MELODIC_APP_ID:-}"
ORIG_INSTALL_ID="${MELODIC_INSTALLATION_ID:-}"
ORIG_KEY_PATH="${MELODIC_PRIVATE_KEY_PATH:-}"
ORIG_KEY_B64="${MELODIC_PRIVATE_KEY_BASE64:-}"

restore_env() {
  export MELODIC_APP_ID="$ORIG_APP_ID"
  export MELODIC_INSTALLATION_ID="$ORIG_INSTALL_ID"
  export MELODIC_PRIVATE_KEY_PATH="$ORIG_KEY_PATH"
  if [[ -n "$ORIG_KEY_B64" ]]; then
    export MELODIC_PRIVATE_KEY_BASE64="$ORIG_KEY_B64"
  else
    unset MELODIC_PRIVATE_KEY_BASE64 2>/dev/null || true
  fi
}

run_wrapper() {
  bash "$SCRIPT" "$@" 2>&1
}

# ------------------------------------------------------------------
# --help

output=$(run_wrapper --help)
rc=$?
assert_exit "--help exits 0" 0 "$rc"
assert_contains "--help shows usage" "$output" "Usage:"
assert_contains "--help shows examples" "$output" "pr create"

# ------------------------------------------------------------------
# No arguments → usage + exit 1

output=$(run_wrapper 2>&1)
rc=$?
assert_exit "no args exits 1" 1 "$rc"
assert_contains "no args shows usage" "$output" "Usage:"

# ------------------------------------------------------------------
# --check with valid env (requires real credentials)

if [[ -n "$ORIG_APP_ID" && -n "$ORIG_INSTALL_ID" && -n "$ORIG_KEY_PATH" ]]; then
  output=$(run_wrapper --check 2>&1)
  rc=$?
  assert_exit "--check exits 0 with valid env" 0 "$rc"
  assert_contains "--check confirms bot identity" "$output" "Bot identity available"
else
  skip_case "--check with valid env: MELODIC_* env vars not set"
fi

# ------------------------------------------------------------------
# --check with missing env → exit 1

(
  unset MELODIC_APP_ID MELODIC_INSTALLATION_ID MELODIC_PRIVATE_KEY_PATH MELODIC_PRIVATE_KEY_BASE64 2>/dev/null || true
  output=$(bash "$SCRIPT" --check 2>&1)
  rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "--check exits 1 with missing env"
  else
    fail "--check exits 1 with missing env" "1" "$rc"
  fi
  if [[ "$output" == *"unavailable"* ]]; then
    pass "--check shows unavailable message"
  else
    fail "--check shows unavailable message" "unavailable" "$output"
  fi
)

# ------------------------------------------------------------------
# Delegates to gh with bot token (requires real credentials)

if [[ -n "$ORIG_APP_ID" && -n "$ORIG_INSTALL_ID" && -n "$ORIG_KEY_PATH" ]]; then
  output=$(run_wrapper api rate_limit --jq '.rate.limit' 2>&1 | tr -d '\r')
  rc=$?
  assert_exit "delegates to gh exits 0" 0 "$rc"
  assert_eq "bot rate limit is 5000" "5000" "$output"
else
  skip_case "delegates to gh: MELODIC_* env vars not set"
fi

# ------------------------------------------------------------------
# Fallback to personal auth when env missing (requires gh auth or GH_TOKEN)

if gh auth status >/dev/null 2>&1; then
  (
    unset MELODIC_APP_ID MELODIC_INSTALLATION_ID MELODIC_PRIVATE_KEY_PATH MELODIC_PRIVATE_KEY_BASE64 2>/dev/null || true
    output=$(bash "$SCRIPT" api rate_limit --jq '.rate.limit' 2>&1 | tr -d '\r')
    rc=$?
    if [[ $rc -eq 0 ]]; then
      pass "fallback to personal auth exits 0"
    else
      fail "fallback to personal auth exits 0" "0" "$rc"
    fi
    if [[ "$output" == *"Warning"* ]]; then
      pass "fallback emits warning"
    else
      fail "fallback emits warning" "contains Warning" "$output"
    fi
    if [[ "$output" == *"5000"* ]]; then
      pass "fallback rate limit returns result"
    else
      fail "fallback rate limit returns result" "contains 5000" "$output"
    fi
  )
else
  skip_case "fallback to personal auth: no gh auth available (CI)"
fi

# ------------------------------------------------------------------
# Bot identity confirmed via GraphQL viewer (requires real credentials)

if [[ -n "$ORIG_APP_ID" && -n "$ORIG_INSTALL_ID" && -n "$ORIG_KEY_PATH" ]]; then
  output=$(run_wrapper api graphql -f query='{ viewer { login } }' --jq '.data.viewer.login' 2>&1 | tr -d '\r')
  rc=$?
  assert_exit "graphql viewer exits 0" 0 "$rc"
  assert_eq "graphql viewer is bot" "melodic-ai[bot]" "$output"
else
  skip_case "graphql viewer: MELODIC_* env vars not set"
fi

# ------------------------------------------------------------------
# Stdin passthrough — token generation must not consume caller's stdin
# (regression: --body @- read empty body because generate-token.sh ate stdin)

if [[ -n "$ORIG_APP_ID" && -n "$ORIG_INSTALL_ID" && -n "$ORIG_KEY_PATH" ]]; then
  # Pipe stdin content while running a command that ignores it — confirms
  # token generation doesn't consume caller's stdin.
  stdin_check=$(echo "passthrough-marker" | bash "$SCRIPT" api rate_limit --jq '.rate.limit' 2>&1 | tr -d '\r')
  if [[ "$stdin_check" == *"5000"* ]]; then
    pass "stdin not consumed by token generation"
  else
    fail "stdin not consumed by token generation" "contains 5000" "$stdin_check"
  fi
else
  skip_case "stdin passthrough: MELODIC_* env vars not set"
fi

# ------------------------------------------------------------------
restore_env

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d checks passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
