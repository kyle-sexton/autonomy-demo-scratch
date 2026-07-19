#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — walltime budget soft/hard caps (Cases I+L hardened for JOBS=8 contention).
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case I: walltime soft cap — advisory warn, no block ---------------
# Per .claude/rules/bash/testing.md "Walltime budget". Override caps to
# 100ms soft / 500ms hard for the test so the fixture sleeps stay short.
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "slow-soft" $'#!/usr/bin/env bash\nsleep 0.2\nprintf "PASS: [1] slept 200ms\\n"\nexit 0'

# HARD cap set to 5000ms (not 500) so the 200ms sleep robustly trips SOFT
# (>100ms) while staying well under HARD under JOBS=8 contention. A 500ms HARD
# could false-trip when a loaded box inflates the 200ms fixture past 500ms,
# making this the one flaky case in the suite. Determinism over a tight band —
# do NOT lower back to 500. (J/K assert HARD fires on a 600ms sleep and keep 500.)
OUT=$(BASH_TEST_WALLTIME_SOFT_MS=100 BASH_TEST_WALLTIME_HARD_MS=5000 run_runner)
RC=$?
assert_exit "I: soft-only violation exits 0 (advisory)" 0 "$RC"
assert_contains "I: Walltime budget header present" "$OUT" "Walltime budget violations"
assert_contains "I: WARN entry for slow-soft" "$OUT" "WARN (>100ms)"
assert_contains "I: slow-soft listed" "$OUT" "slow-soft.test.sh"
assert_not_contains "I: no HARD entry" "$OUT" "HARD (>5000ms)"

# --- Case J: walltime hard cap, gating disabled (default) → no block ----
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "slow-hard" $'#!/usr/bin/env bash\nsleep 0.6\nprintf "PASS: [1] slept 600ms\\n"\nexit 0'

OUT=$(BASH_TEST_WALLTIME_SOFT_MS=100 BASH_TEST_WALLTIME_HARD_MS=500 run_runner)
RC=$?
assert_exit "J: hard violation without HARD_ENABLED exits 0" 0 "$RC"
assert_contains "J: HARD entry for slow-hard" "$OUT" "HARD (>500ms)"
assert_contains "J: slow-hard listed" "$OUT" "slow-hard.test.sh"

# --- Case K: walltime hard cap, gating ENABLED → blocks ----------------
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "slow-hard-blocking" $'#!/usr/bin/env bash\nsleep 0.6\nprintf "PASS: [1] slept 600ms\\n"\nexit 0'

OUT=$(BASH_TEST_WALLTIME_SOFT_MS=100 BASH_TEST_WALLTIME_HARD_MS=500 \
  BASH_TEST_WALLTIME_HARD_ENABLED=true run_runner)
RC=$?
assert_exit "K: hard violation with HARD_ENABLED exits 1" 1 "$RC"
assert_contains "K: hard violation message surfaces" "$OUT" "exceeded hard walltime cap"
assert_contains "K: HARD entry for slow-hard-blocking" "$OUT" "slow-hard-blocking.test.sh"

# --- Case L: fast test → no budget output -----------------------------
# Caps at production defaults (30s soft / 50s hard) so a genuinely-fast test
# stays under SOFT even when JOBS=8 contention inflates its wall to a few
# seconds. A tight 100ms SOFT here false-tripped under heavy load (the fixture's
# bash-startup wall exceeded 100ms → spurious "Walltime budget violations") —
# same contention-fragility class as Case I. The no-violation path is what this
# case verifies; determinism over a tight band.
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "fast" $'#!/usr/bin/env bash\nprintf "PASS: [1] fast\\n"\nexit 0'

OUT=$(BASH_TEST_WALLTIME_SOFT_MS=30000 BASH_TEST_WALLTIME_HARD_MS=50000 run_runner)
RC=$?
assert_exit "L: fast test exits 0" 0 "$RC"
assert_not_contains "L: no budget section when no violations" "$OUT" "Walltime budget violations"

report
