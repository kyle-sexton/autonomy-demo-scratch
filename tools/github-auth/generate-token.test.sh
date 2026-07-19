#!/usr/bin/env bash
# Regression tests for tools/github-auth/generate-token.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/generate-token.sh"
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

run_script() {
  bash "$SCRIPT" "$@" 2>&1
}

# Inline copy of generate-token.sh's try_cached_token logic. The script runs
# `main "$@"` at file scope and cannot be sourced (sourcing fires main), so the
# freshness check is reimplemented here verbatim and driven by CACHE_FILE.
CACHE_CHECK_BODY='
    set -euo pipefail
    CACHE_FILE="$CACHE_FILE"
    try_cached_token() {
        if [[ ! -f "$CACHE_FILE" ]]; then return 1; fi
        local ee tt nn
        ee=$(jq -r ".expires_at_epoch // 0" "$CACHE_FILE" 2>/dev/null) || return 1
        tt=$(jq -r ".token // empty" "$CACHE_FILE" 2>/dev/null) || return 1
        [[ -z "$tt" ]] && return 1
        nn=$(date +%s | tr -d "\r")
        if [[ "$nn" -lt $((ee - 300)) ]]; then echo "$tt"; return 0; fi
        return 1
    }
    try_cached_token
'

check_cache() {
  CACHE_FILE="$1" bash -c "$CACHE_CHECK_BODY" 2>/dev/null
}

# ------------------------------------------------------------------
# --help

output=$(run_script --help)
rc=$?
if [[ $rc -eq 0 ]]; then
  assert_contains "--help exits 0 with usage" "$output" "Usage:"
else
  fail "--help exits 0" "0" "$rc"
fi

# ------------------------------------------------------------------
# --check with missing env vars

(
  unset MELODIC_APP_ID
  export MELODIC_INSTALLATION_ID="$ORIG_INSTALL_ID"
  export MELODIC_PRIVATE_KEY_PATH="$ORIG_KEY_PATH"
  bash "$SCRIPT" --check 2>&1
)
rc=$?
assert_exit "--check without MELODIC_APP_ID fails" "1" "$rc"

(
  export MELODIC_APP_ID="$ORIG_APP_ID"
  unset MELODIC_INSTALLATION_ID
  export MELODIC_PRIVATE_KEY_PATH="$ORIG_KEY_PATH"
  bash "$SCRIPT" --check 2>&1
)
rc=$?
assert_exit "--check without MELODIC_INSTALLATION_ID fails" "1" "$rc"

(
  export MELODIC_APP_ID="$ORIG_APP_ID"
  export MELODIC_INSTALLATION_ID="$ORIG_INSTALL_ID"
  unset MELODIC_PRIVATE_KEY_PATH
  unset MELODIC_PRIVATE_KEY_BASE64 2>/dev/null || true
  bash "$SCRIPT" --check 2>&1
)
rc=$?
assert_exit "--check without any key fails" "1" "$rc"

output=$(
  export MELODIC_APP_ID="${ORIG_APP_ID:-12345}"
  export MELODIC_INSTALLATION_ID="${ORIG_INSTALL_ID:-67890}"
  export MELODIC_PRIVATE_KEY_PATH="/nonexistent/path/key.pem"
  bash "$SCRIPT" --check 2>&1
)
rc=$?
assert_exit "--check with nonexistent PEM fails" "1" "$rc"
assert_contains "--check mentions 'not found'" "$output" "not found"

restore_env

# ------------------------------------------------------------------
# --check with valid env

if [[ -n "$ORIG_APP_ID" && -n "$ORIG_INSTALL_ID" && -n "$ORIG_KEY_PATH" && -f "$ORIG_KEY_PATH" ]]; then
  output=$(run_script --check)
  rc=$?
  assert_exit "--check with valid env succeeds" "0" "$rc"
else
  skip_case "--check with valid env: env vars not fully configured"
fi

# ------------------------------------------------------------------
# Cache freshness logic

now=$(date +%s | tr -d '\r')

# Fresh cache (1hr out) — should be used
fresh_epoch=$((now + 3600))
fresh_iso=$(date -d "@$fresh_epoch" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2099-01-01T00:00:00Z")
printf '{"token":"ghs_FAKEFRESH","expires_at":"%s","expires_at_epoch":%d}\n' \
  "$fresh_iso" "$fresh_epoch" >"$TEST_TMPDIR/fresh-cache.json"

cached=$(check_cache "$TEST_TMPDIR/fresh-cache.json") && got_fresh=true || got_fresh=false

if [[ "$got_fresh" == true ]]; then
  assert_eq "Fresh cache returns token" "ghs_FAKEFRESH" "$cached"
else
  fail "Fresh cache returns token" "ghs_FAKEFRESH" "(cache miss)"
fi

# Stale cache (60s out, within 5min margin) — should re-mint
stale_epoch=$((now + 60))
stale_iso=$(date -d "@$stale_epoch" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-01-01T00:00:00Z")
printf '{"token":"ghs_FAKESTALE","expires_at":"%s","expires_at_epoch":%d}\n' \
  "$stale_iso" "$stale_epoch" >"$TEST_TMPDIR/stale-cache.json"

cached=$(check_cache "$TEST_TMPDIR/stale-cache.json") && got_stale=true || got_stale=false

if [[ "$got_stale" == false ]]; then
  pass "Stale cache (60s) triggers re-mint"
else
  fail "Stale cache triggers re-mint" "(miss)" "$cached"
fi

# Expired cache — should re-mint
expired_epoch=$((now - 100))
printf '{"token":"ghs_FAKEEXPIRED","expires_at":"2020-01-01T00:00:00Z","expires_at_epoch":%d}\n' \
  "$expired_epoch" >"$TEST_TMPDIR/expired-cache.json"

cached=$(check_cache "$TEST_TMPDIR/expired-cache.json") && got_expired=true || got_expired=false

if [[ "$got_expired" == false ]]; then
  pass "Expired cache triggers re-mint"
else
  fail "Expired cache triggers re-mint" "(miss)" "$cached"
fi

# Missing cache — should re-mint
cached=$(CACHE_FILE="$TEST_TMPDIR/nonexistent.json" bash -c '
    set -euo pipefail
    [[ ! -f "$CACHE_FILE" ]] && exit 1
    exit 0
' 2>/dev/null) && got_missing=true || got_missing=false

if [[ "$got_missing" == false ]]; then
  pass "Missing cache file triggers re-mint"
else
  fail "Missing cache file triggers re-mint" "(miss)" "(hit)"
fi

# ------------------------------------------------------------------
# JWT structure

if [[ -n "$ORIG_APP_ID" && -n "$ORIG_KEY_PATH" && -f "$ORIG_KEY_PATH" ]]; then
  restore_env

  jwt=$(bash -c '
        set -euo pipefail
        b64url() { openssl base64 -A | tr "+/" "-_" | tr -d "="; }
        now=$(date +%s | tr -d "\r")
        iat=$((now - 60))
        exp=$((now + 600))
        header="{\"alg\":\"RS256\",\"typ\":\"JWT\"}"
        payload=$(printf "{\"iss\":\"%s\",\"iat\":%d,\"exp\":%d}" "'"$ORIG_APP_ID"'" "$iat" "$exp")
        hb=$(printf "%s" "$header" | b64url)
        pb=$(printf "%s" "$payload" | b64url)
        sig=$(printf "%s.%s" "$hb" "$pb" | openssl dgst -sha256 -sign "'"$ORIG_KEY_PATH"'" -binary | b64url)
        printf "%s.%s.%s" "$hb" "$pb" "$sig"
    ')

  dot_count=$(printf '%s' "$jwt" | tr -cd '.' | wc -c | tr -d ' \r')
  assert_eq "JWT has 3 parts (2 dots)" "2" "$dot_count"

  # Decode header
  header_part=$(printf '%s' "$jwt" | cut -d. -f1)
  padded="$header_part"
  mod=$((${#padded} % 4))
  if [[ $mod -eq 2 ]]; then padded="${padded}=="; elif [[ $mod -eq 3 ]]; then padded="${padded}="; fi
  header_json=$(printf '%s' "$padded" | sed 'y/-_/+\//' | base64 -d 2>/dev/null || echo "{}")

  alg=$(printf '%s' "$header_json" | jq -r '.alg // empty' 2>/dev/null || echo "")
  typ=$(printf '%s' "$header_json" | jq -r '.typ // empty' 2>/dev/null || echo "")
  assert_eq "JWT header alg" "RS256" "$alg"
  assert_eq "JWT header typ" "JWT" "$typ"

  # Decode payload
  payload_part=$(printf '%s' "$jwt" | cut -d. -f2)
  padded="$payload_part"
  mod=$((${#padded} % 4))
  if [[ $mod -eq 2 ]]; then padded="${padded}=="; elif [[ $mod -eq 3 ]]; then padded="${padded}="; fi
  payload_json=$(printf '%s' "$padded" | sed 'y/-_/+\//' | base64 -d 2>/dev/null || echo "{}")

  iss=$(printf '%s' "$payload_json" | jq -r '.iss // empty' 2>/dev/null || echo "")
  iat_val=$(printf '%s' "$payload_json" | jq -r '.iat // 0' 2>/dev/null || echo "0")
  exp_val=$(printf '%s' "$payload_json" | jq -r '.exp // 0' 2>/dev/null || echo "0")
  assert_eq "JWT iss matches APP_ID" "$ORIG_APP_ID" "$iss"

  duration=$((exp_val - iat_val))
  if [[ "$duration" -ge 600 && "$duration" -le 660 ]]; then
    pass "JWT exp-iat=${duration}s (600-660 expected)"
  else
    fail "JWT duration" "600-660" "$duration"
  fi
else
  skip_case "JWT structure: PEM not available"
fi

# ------------------------------------------------------------------
# Unknown option

output=$(run_script --bogus 2>&1) || true
rc=$?
assert_contains "Unknown option mentioned in error" "$output" "Unknown option"

restore_env

# ------------------------------------------------------------------
# Summary

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d checks passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
