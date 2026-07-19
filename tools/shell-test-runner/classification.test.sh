#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — result classification (PASS/SKIP/PARTIAL/FAIL/empty/mixed + skip_suite).
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case A: single PASS-only fixture ----------------------------------
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "pass-only" $'#!/usr/bin/env bash\nprintf "PASS: [1] sample\\n"\nexit 0'

OUT=$(run_runner)
RC=$?
assert_exit "A: pass-only exits 0" 0 "$RC"
assert_contains "A: summary counts 1 passed" "$OUT" "1 passed"
assert_contains "A: summary counts 0 skipped" "$OUT" "0 skipped"
assert_contains "A: summary counts 0 failed" "$OUT" "0 failed"
assert_not_contains "A: no Wholly skipped section" "$OUT" "Wholly skipped"
assert_not_contains "A: no Partial coverage section" "$OUT" "Partial coverage"

# --- Case B: SKIP-only fixture (wholly-skipped) ------------------------
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "skip-only" $'#!/usr/bin/env bash\nprintf "SKIP: tool not on PATH\\n" >&2\nexit 0'

OUT=$(run_runner)
RC=$?
assert_exit "B: skip-only exits 0 (skip is not failure)" 0 "$RC"
assert_contains "B: summary counts 1 skipped" "$OUT" "1 skipped"
assert_contains "B: summary counts 0 passed" "$OUT" "0 passed"
assert_contains "B: Wholly skipped section present" "$OUT" "Wholly skipped"
assert_contains "B: skipped file listed" "$OUT" "skip-only.test.sh"

# --- Case C: PARTIAL (PASS + SKIP in same file) ------------------------
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "partial" $'#!/usr/bin/env bash\nprintf "SKIP: case 1 needs net\\n" >&2\nprintf "PASS: [1] case 2 ran\\n"\nexit 0'

OUT=$(run_runner)
RC=$?
assert_exit "C: partial exits 0" 0 "$RC"
assert_contains "C: summary counts 1 partial" "$OUT" "1 partial"
assert_contains "C: Partial coverage section present" "$OUT" "Partial coverage"
assert_contains "C: partial file listed" "$OUT" "partial.test.sh"
assert_contains "C: skip count surfaced" "$OUT" "(1 skip)"

# --- Case D: FAIL (non-zero exit) --------------------------------------
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "fail" $'#!/usr/bin/env bash\nprintf "PASS: [1] one\\n"\nexit 1'

OUT=$(run_runner)
RC=$?
assert_exit "D: fail exits 1" 1 "$RC"
assert_contains "D: summary counts 1 failed" "$OUT" "1 failed"
assert_contains "D: failure list shows file" "$OUT" "fail.test.sh"

# --- Case E: empty (no markers, exit 0) — tolerated as PASS ------------
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "empty" $'#!/usr/bin/env bash\necho "doing something"\nexit 0'

OUT=$(run_runner)
RC=$?
assert_exit "E: empty exits 0" 0 "$RC"
assert_contains "E: empty counted as passed" "$OUT" "1 passed"

# --- Case F: mixed suite — one of each --------------------------------
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "f1-pass" $'#!/usr/bin/env bash\nprintf "PASS: [1] ok\\n"\nexit 0'
make_fixture "f2-skip" $'#!/usr/bin/env bash\nprintf "SKIP: missing tool\\n" >&2\nexit 0'
make_fixture "f3-partial" $'#!/usr/bin/env bash\nprintf "SKIP: half\\n" >&2\nprintf "PASS: [1] half\\n"\nexit 0'

OUT=$(run_runner)
RC=$?
assert_exit "F: mixed (no fail) exits 0" 0 "$RC"
assert_contains "F: summary 3 file(s)" "$OUT" "3 test file(s)"
assert_contains "F: 1 passed" "$OUT" "1 passed"
assert_contains "F: 1 partial" "$OUT" "1 partial"
assert_contains "F: 1 skipped" "$OUT" "1 skipped"
assert_contains "F: 0 failed" "$OUT" "0 failed"

# --- Case G: zero matches → exit 0, no summary -------------------------
rm -f "$TEST_TMPDIR"/*.test.sh
OUT=$(run_runner 2>&1)
RC=$?
assert_exit "G: empty dir exits 0" 0 "$RC"
assert_contains "G: empty dir reports no files" "$OUT" "No *.test.sh files found."

# --- Case H: skip_suite primitive integration --------------------------
# Verifies that a test using lib.sh's skip_suite produces the SKIP marker
# the runner recognizes.
rm -f "$TEST_TMPDIR"/*.test.sh
LIB_PATH="${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"
make_fixture "lib-skip" "#!/usr/bin/env bash
source '$LIB_PATH'
skip_suite 'integration check'"

OUT=$(run_runner)
RC=$?
assert_exit "H: skip_suite exits 0" 0 "$RC"
assert_contains "H: skip_suite classified as skipped" "$OUT" "1 skipped"
assert_contains "H: lib-skip listed" "$OUT" "lib-skip.test.sh"

report
