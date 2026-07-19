#!/usr/bin/env bash
# Regression tests for launcher.js npx dispatch (cross-platform npx spawn).
#
# Black-box subprocess tests — invoke the launcher as a child process and
# assert on exit code and stdout. Cross-platform (Windows/macOS/Linux).
#
# Signal-forwarding and exit-code polish coverage live in
# repo-dispatch.test.sh — repo mode accepts an arbitrary command,
# making it trivial to wire to a long-running child for deterministic
# signal assertions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/launcher.js"

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# T1: --version reaches npx and exits 0 (proves cross-platform spawn end-to-end)
EXIT_CODE=0
MCP_LAUNCHER_FNM_ACTIVE=1 node "$SCRIPT" --version >/dev/null 2>&1 || EXIT_CODE=$?
assert_exit "T1: --version exits 0" 0 "$EXIT_CODE"

# T2: --version produces non-empty stdout (proves stdio passthrough works)
OUTPUT=$(MCP_LAUNCHER_FNM_ACTIVE=1 node "$SCRIPT" --version 2>/dev/null)
CASE_NUM=$((CASE_NUM + 1))
if [[ -n "$OUTPUT" ]]; then
  printf 'PASS: [%d] T2: --version produces stdout (%q)\n' "$CASE_NUM" "$OUTPUT"
else
  printf 'FAIL: [%d] T2: --version produced empty stdout\n' "$CASE_NUM" >&2
  FAILED=$((FAILED + 1))
fi

# T3-T5: dispatch() guard rejects unrecognized non-npx path forms. Bare
# package specs (`react`, `@azure/mcp`, `-y`) route to npx; explicit path
# forms must either start with `mcp-servers/` (repo mode) or be rejected
# with a clear diagnostic before npx sees them.
#
# Note: on Git Bash, MSYS aggressively translates leading `/path` args to
# `C:\Program Files\Git\path` (mount-root substitution), not the verbatim
# string. Use `//absolute/path` (double-leading slash) which MSYS passes
# through as `/absolute/path` — the form a Linux JSON-literal would
# produce. The leading-`/` guard branch fires there.
for arg in "./relative/path" "//absolute/path" 'C:\windows\path'; do
  EXIT_CODE=0
  OUTPUT=$(MCP_LAUNCHER_FNM_ACTIVE=1 node "$SCRIPT" "$arg" 2>&1) || EXIT_CODE=$?
  label="T3-5: '$arg' rejected with non-zero exit"
  CASE_NUM=$((CASE_NUM + 1))
  if [[ "$EXIT_CODE" -ne 0 ]] && [[ "$OUTPUT" == *"unrecognized server path"* ]]; then
    printf 'PASS: [%d] %s (exit=%d)\n' "$CASE_NUM" "$label" "$EXIT_CODE"
  else
    printf 'FAIL: [%d] %s — exit=%d output=%q\n' "$CASE_NUM" "$label" "$EXIT_CODE" "$OUTPUT" >&2
    FAILED=$((FAILED + 1))
  fi
done

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d test(s) passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d of %d test(s) failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
