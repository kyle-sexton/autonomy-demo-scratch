#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — per-test timeout backstop + RESULTS_DIR self-sweep.
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case Q: per-test timeout (F2) kills a hung test -------------------
# A test that never returns must be killed at the per-test cap instead of
# blocking the runner forever. Override the cap to 2s (kill-after 1s) so the
# fixture's `sleep 9999` is reaped quickly. Classified FAIL (non-zero exit),
# with a TIMEOUT annotation in the replayed log. Skipped when no timeout
# binary is present (the runner falls back to un-timed `bash "$t"`, so the
# hang fixture would block forever — not exercisable on that platform).
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  rm -f "$TEST_TMPDIR"/*.test.sh
  make_fixture "hang" $'#!/usr/bin/env bash\nprintf "PASS: [1] before hang\\n"\nsleep 9999\nexit 0'

  Q_START=$EPOCHREALTIME
  # F2 defaults OFF (opt-in) — enable it explicitly here, else the sleep 9999
  # fixture would run unbounded and hang this self-test.
  OUT=$(BASH_TEST_PER_TEST_TIMEOUT_ENABLED=true BASH_TEST_PER_TEST_TIMEOUT_SECS=2 BASH_TEST_PER_TEST_TIMEOUT_KILL_AFTER_SECS=1 run_runner)
  RC=$?
  Q_END=$EPOCHREALTIME
  Q_ELAPSED=$(awk -v s="$Q_START" -v e="$Q_END" 'BEGIN{printf "%.0f", e-s}')
  assert_exit "Q: hung test exits 1 (timed-out test fails)" 1 "$RC"
  assert_contains "Q: hung test in failure list" "$OUT" "hang.test.sh"
  assert_contains "Q: TIMEOUT annotation surfaced" "$OUT" "TIMEOUT: exceeded 2s per-test cap"
  # Completed far under the 9999s sleep — proves the timeout fired. A 60s
  # ceiling tolerates a loaded CI box without flaking on the 2s+1s budget.
  CASE_NUM=$((CASE_NUM + 1))
  if [[ "$Q_ELAPSED" -lt 60 ]]; then
    printf 'PASS: [%d] Q: runner completed in %ss (timeout fired, no infinite hang)\n' "$CASE_NUM" "$Q_ELAPSED"
  else
    printf 'FAIL: [%d] Q: runner took %ss — timeout did not fire\n' "$CASE_NUM" "$Q_ELAPSED" >&2
    FAILED=$((FAILED + 1))
  fi
else
  skip_case "Q: no timeout/gtimeout binary — per-test timeout not exercisable"
fi

# --- Case S: RESULTS_DIR self-sweep (F4) reclaims own stale leaks -------
# The runner prefixes its temp dir `run-shell-tests.*` and, at startup, sweeps
# prior runs' leaked dirs older than 4h. Verify a backdated dir is reclaimed
# while a fresh one (a possible concurrent run) is left untouched. Skipped when
# `touch` cannot backdate an mtime (sweep not exercisable on that platform).
SWEEP_PARENT="${TMPDIR:-/tmp}"
SWEEP_OLD="$SWEEP_PARENT/run-shell-tests.SELFTEST-old-$$"
SWEEP_NEW="$SWEEP_PARENT/run-shell-tests.SELFTEST-new-$$"
mkdir -p "$SWEEP_OLD" "$SWEEP_NEW"
touch -d '5 hours ago' "$SWEEP_OLD" 2>/dev/null || true
if find "$SWEEP_PARENT" -maxdepth 1 -name "run-shell-tests.SELFTEST-old-$$" -mmin +240 2>/dev/null | grep -q .; then
  rm -f "$TEST_TMPDIR"/*.test.sh
  make_fixture "sweep-trigger" $'#!/usr/bin/env bash\nprintf "PASS: [1] trigger\\n"\nexit 0'
  run_runner >/dev/null 2>&1
  CASE_NUM=$((CASE_NUM + 1))
  if [[ ! -d "$SWEEP_OLD" ]]; then
    printf 'PASS: [%d] S: stale run-shell-tests.* dir (>4h) swept\n' "$CASE_NUM"
  else
    printf 'FAIL: [%d] S: stale dir not swept\n' "$CASE_NUM" >&2
    FAILED=$((FAILED + 1))
  fi
  CASE_NUM=$((CASE_NUM + 1))
  if [[ -d "$SWEEP_NEW" ]]; then
    printf 'PASS: [%d] S: fresh run-shell-tests.* dir (concurrent run) preserved\n' "$CASE_NUM"
  else
    printf 'FAIL: [%d] S: fresh dir wrongly swept (would corrupt a concurrent run)\n' "$CASE_NUM" >&2
    FAILED=$((FAILED + 1))
  fi
else
  skip_case "S: touch could not backdate mtime — self-sweep not exercisable"
fi
rm -rf "$SWEEP_OLD" "$SWEEP_NEW"

# --- Case T: git-hook env scrub (GIT_DIR / GIT_COMMON_DIR) --------------
# A suite run from a git hook (the pre-push shell-test-walltime lane) inherits
# git's exported GIT_DIR / GIT_COMMON_DIR. Those override `git -C <fixture>` and
# even `git init` in every fixture, silently retargeting the REAL repo — leaking
# worktrees into the real hub and clobbering refs/remotes/origin/main via fixture
# `git update-ref`. The runner unsets them right after `cd "$ROOT_DIR"`. Probe: a
# fixture that fails if it still sees either var in its inherited environment.
# Both point at a nonexistent throwaway path so the probe can never reach a real
# repo even if the scrub regressed (the regression surfaces as a FAIL, not a
# corrupting run).
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "git-env-probe" $'#!/usr/bin/env bash\nif [[ -z "${GIT_DIR:-}" && -z "${GIT_COMMON_DIR:-}" ]]; then\n  printf "PASS: [1] git env scrubbed in child\\n"\nelse\n  printf "FAIL: [1] git env leaked: GIT_DIR=%s GIT_COMMON_DIR=%s\\n" "${GIT_DIR:-}" "${GIT_COMMON_DIR:-}"\n  exit 1\nfi\nexit 0'
T_OUT=$(GIT_DIR="$TEST_TMPDIR/throwaway.git" GIT_COMMON_DIR="$TEST_TMPDIR/throwaway.git" run_runner)
T_RC=$?
assert_exit "T: runner scrubs leaked git env (probe fixture passes)" 0 "$T_RC"
assert_contains "T: probe confirms GIT_DIR/GIT_COMMON_DIR unset in child" "$T_OUT" "git env scrubbed in child"

report
