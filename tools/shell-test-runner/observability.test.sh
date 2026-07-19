#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — shell-test-timings.jsonl emission (gated).
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case M: shell-test-timings.jsonl emission (gated) ----------------
# Default (env unset) — no file written.
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "obs-test" $'#!/usr/bin/env bash\nprintf "PASS: [1] obs\\n"\nexit 0'

OBS_REPO_ROOT="$TEST_TMPDIR"
mkdir -p "$OBS_REPO_ROOT/.claude/observability"
JSONL="$OBS_REPO_ROOT/.claude/observability/shell-test-timings.jsonl"
rm -f "$JSONL"

# Override REPO_ROOT detection by running from inside TEST_TMPDIR.
# Default invocation: no write expected.
(cd "$OBS_REPO_ROOT" && bash "$RUNNER" "$OBS_REPO_ROOT" >/dev/null 2>&1)
CASE_NUM=$((CASE_NUM + 1))
if [[ ! -f "$JSONL" ]]; then
  printf 'PASS: [%d] M1: JSONL not written when env unset\n' "$CASE_NUM"
else
  printf 'FAIL: [%d] M1: JSONL written despite env unset\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
fi

# Gate enabled — JSONL written. master + per-feature must both be true.
# CLAUDE_PROJECT_DIR override points the writer at the test tmpdir per
# observability/conventions.md "Storage" convention.
(cd "$OBS_REPO_ROOT" \
  && CLAUDE_PROJECT_DIR="$OBS_REPO_ROOT" \
    HOOK_OBSERVABILITY_LOG_ENABLED=true HOOK_SHELL_TEST_TIMING_ENABLED=true \
    bash "$RUNNER" "$OBS_REPO_ROOT" >/dev/null 2>&1)
CASE_NUM=$((CASE_NUM + 1))
if [[ -f "$JSONL" ]]; then
  printf 'PASS: [%d] M2: JSONL written when both env vars true\n' "$CASE_NUM"
else
  printf 'FAIL: [%d] M2: JSONL missing despite env enabled\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
fi

# All lines valid JSON.
CASE_NUM=$((CASE_NUM + 1))
if jq empty "$JSONL" 2>/dev/null; then
  printf 'PASS: [%d] M3: all JSONL lines parse as valid JSON\n' "$CASE_NUM"
else
  printf 'FAIL: [%d] M3: JSONL contains malformed lines\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
fi

# Per-test line shape: test_file field matches fixture name.
# Use grep+jq directly because assert_jsonl_field reads only the LAST line
# (which is __total__ here, not the per-test entry).
CASE_NUM=$((CASE_NUM + 1))
if grep -q '"test_file":"obs-test.test.sh"' "$JSONL"; then
  printf 'PASS: [%d] M4: per-test line emitted with test_file path\n' "$CASE_NUM"
else
  printf 'FAIL: [%d] M4: per-test line missing test_file\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
fi

# duration_ms field is numeric on every line.
CASE_NUM=$((CASE_NUM + 1))
if jq -r '.duration_ms | tostring' "$JSONL" 2>/dev/null | grep -vqE '^[0-9]+$'; then
  printf 'FAIL: [%d] M5: non-numeric duration_ms\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
else
  printf 'PASS: [%d] M5: duration_ms numeric on all lines\n' "$CASE_NUM"
fi

# __total__ summary line present.
CASE_NUM=$((CASE_NUM + 1))
if grep -q '"test_file":"__total__"' "$JSONL"; then
  printf 'PASS: [%d] M6: __total__ summary line emitted\n' "$CASE_NUM"
else
  printf 'FAIL: [%d] M6: no __total__ line in JSONL\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
fi

report
