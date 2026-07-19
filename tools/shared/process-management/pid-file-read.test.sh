#!/usr/bin/env bash
# Regression tests for tools/shared/process-management/pid-file-read.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"
# shellcheck source=./pid-file-read.sh
source "$SCRIPT_DIR/pid-file-read.sh"

# --- Case 1: clean numeric PID returned unchanged ---
PID1="$TEST_TMPDIR/p1.pid"
printf '12345' >"$PID1"
OUT=$(pid_file::read "$PID1")
assert_eq "clean PID returned" "12345" "$OUT"

# --- Case 2: trailing newline stripped ---
PID2="$TEST_TMPDIR/p2.pid"
printf '12345\n' >"$PID2"
OUT=$(pid_file::read "$PID2")
assert_eq "trailing newline stripped" "12345" "$OUT"

# --- Case 3: CRLF stripped (Git Bash producer) ---
PID3="$TEST_TMPDIR/p3.pid"
printf '12345\r\n' >"$PID3"
OUT=$(pid_file::read "$PID3")
assert_eq "CRLF stripped" "12345" "$OUT"

# --- Case 4: leading + trailing whitespace stripped ---
PID4="$TEST_TMPDIR/p4.pid"
printf '  12345  \t\n' >"$PID4"
OUT=$(pid_file::read "$PID4")
assert_eq "whitespace stripped" "12345" "$OUT"

# --- Case 5: empty file → empty output, success ---
PID5="$TEST_TMPDIR/p5.pid"
: >"$PID5"
OUT=$(pid_file::read "$PID5")
assert_eq "empty file → empty output" "" "$OUT"

# --- Case 6: missing file → empty output, non-zero exit ---
OUT=$(pid_file::read "$TEST_TMPDIR/does-not-exist" 2>/dev/null || echo FALLBACK)
assert_eq "missing file → caller fallback fires" "FALLBACK" "$OUT"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
