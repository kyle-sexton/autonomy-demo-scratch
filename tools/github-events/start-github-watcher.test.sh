#!/usr/bin/env bash
# Regression tests for tools/github-events/start-github-watcher.sh.
#
# Black-box: invoke the supervisor as a subprocess with env overrides.
# No real network — exercises argv parsing, the concurrent-invocation guard,
# stale-PID cleanup, the dry-run / help emit paths, and the daemon-by-default
# fork/readiness flow added for daemon-by-default mode. Wiring through real
# `gh webhook forward` or a live MCP /health endpoint is covered by Phase 5
# /test integration, not here.
#
# Run: bash tools/github-events/start-github-watcher.test.sh
# Or:  bash tools/run-shell-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/start-github-watcher.sh"
TEST_TMPDIR="$(mktemp -d)"

cleanup() {
  # Kill any leftover daemon children spawned by tests. Best-effort — if a
  # PID file points at a still-alive process, SIGTERM it; ignore failures.
  # CRITICAL: Cases E + E2 seed PID files with $$ (this test's own PID) to
  # exercise the live-PID lock-matrix branch. NEVER signal $$ from cleanup —
  # SIGTERM to self during the EXIT trap causes bash to exit non-zero (143),
  # which the runner classifies as FAIL even though all assertions passed.
  local pidf my_pid="$$"
  for pidf in "$TEST_TMPDIR"/*.pid; do
    [[ -f "$pidf" ]] || continue
    local p
    p=$(tr -d '\r\n[:space:]' <"$pidf" 2>/dev/null || true)
    [[ -z "$p" || "$p" == "$my_pid" ]] && continue
    kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Helper: kill a PID if alive, swallow errors.
kill_if_alive() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null
  # Wait briefly for graceful exit.
  local i=0
  while ((i < 5)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# --- Case R: script no longer uses SCRIPT_DIR/../.. for path resolution -------
# The old path resolution (`cd SCRIPT_DIR/../..`) failed from worktrees without
# build artifacts. Verify the fix uses git-based resolution instead.
SCRIPT_BODY=$(cat "$SCRIPT")
if [[ "$SCRIPT_BODY" != *'SCRIPT_DIR/../..'* ]]; then
  pass "R: no SCRIPT_DIR/../.. path resolution"
else
  fail "R: no SCRIPT_DIR/../.. path resolution" "absent" "still present"
fi
if [[ "$SCRIPT_BODY" == *'resolve_repo_root'* ]]; then
  pass "R: uses resolve_repo_root helper"
else
  fail "R: uses resolve_repo_root helper" "present" "missing"
fi
if [[ "$SCRIPT_BODY" == *'ensure_broker_built'* ]]; then
  pass "R: uses ensure_broker_built helper"
else
  fail "R: uses ensure_broker_built helper" "present" "missing"
fi

# --- Case T: REPO derives from repo identity, not a hardcoded single repo ------
# Success criterion #5: no `melodic-software/medley` as the sole repo source.
if [[ "$SCRIPT_BODY" != *'GITHUB_EVENTS_REPO:-melodic-software/medley'* ]]; then
  pass "T: no hardcoded melodic-software/medley REPO default"
else
  fail "T: no hardcoded melodic-software/medley REPO default" "absent" "still present"
fi
# Match the bare token (unique to the REPO assignment) — avoids embedding ${...}
# in a single-quoted literal (SC2016 noise) while still pinning the source.
if [[ "$SCRIPT_BODY" == *'GHE_REPO_IDENTITY'* ]]; then
  pass "T: REPO sourced from GHE_REPO_IDENTITY"
else
  fail "T: REPO sourced from GHE_REPO_IDENTITY" "present" "missing"
fi
# Env override still flows through the identity → REPO → plan banner.
OUT_T=$(GITHUB_EVENTS_REPO=test-owner/test-repo bash "$SCRIPT" --dry-run 2>&1)
assert_contains "T: GITHUB_EVENTS_REPO override reflected in plan" "$OUT_T" "test-owner/test-repo"

# --- Case U: watcher reconciles the stale relay hook before the forwarder ------
if [[ "$SCRIPT_BODY" == *'ensure_no_stale_cli_hook'* ]]; then
  pass "U: watcher calls ensure_no_stale_cli_hook"
else
  fail "U: watcher calls ensure_no_stale_cli_hook" "present" "missing"
fi
# Reconcile must precede the forwarder launch (delete-then-recreate, not after).
# Match the call invocation (`! ghe::ensure_no_stale_cli_hook`) so comments that
# merely mention the function name do not skew the line number.
RECONCILE_LINE=$(grep -n '! ghe::ensure_no_stale_cli_hook' "$SCRIPT" | head -1 | cut -d: -f1)
# Anchor to the command at column 0 — the header comment also mentions
# "gh webhook forward" in prose, which a bare match would pick up first.
FORWARD_LINE=$(grep -n '^gh webhook forward' "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$RECONCILE_LINE" && -n "$FORWARD_LINE" && "$RECONCILE_LINE" -lt "$FORWARD_LINE" ]]; then
  pass "U: reconcile call precedes the forwarder launch"
else
  fail "U: reconcile call precedes the forwarder launch" "reconcile<forward" "reconcile=$RECONCILE_LINE forward=$FORWARD_LINE"
fi

# --- Case A: --help exits 0 + emits banner ------------------------------------
OUT_A=$(bash "$SCRIPT" --help 2>&1)
RC_A=$?
assert_exit "A: --help exit 0" 0 "$RC_A"
assert_contains "A: --help shows usage banner" "$OUT_A" "Supervisor for"
assert_contains "A: --help describes 2-step readiness" "$OUT_A" "PID file"
assert_contains "A: --help mentions --foreground" "$OUT_A" "--foreground"
# Guard against header growth truncating the Usage block out of the --help window
# (the dynamic sed boundary must still reach the usage examples).
assert_contains "A: --help shows Usage examples" "$OUT_A" "Usage:"
assert_contains "A: --help shows --dry-run usage example" "$OUT_A" "--dry-run"

# --- Case B: --dry-run exits 0 + emits plan -----------------------------------
OUT_B=$(bash "$SCRIPT" --dry-run 2>&1)
RC_B=$?
assert_exit "B: --dry-run exit 0" 0 "$RC_B"
assert_contains "B: --dry-run says complete" "$OUT_B" "Dry-run complete"
assert_contains "B: --dry-run shows port" "$OUT_B" "port:"
assert_contains "B: --dry-run shows pid file" "$OUT_B" "pid file:"
assert_contains "B: --dry-run shows webhook url line" "$OUT_B" "webhook url:"
assert_contains "B: --dry-run shows daemon log path" "$OUT_B" "daemon log:"
assert_contains "B: --dry-run shows ready timeout" "$OUT_B" "ready timeout:"
assert_contains "B: --dry-run shows default mode is daemon" "$OUT_B" "mode:           daemon"

# --- Case B2: --foreground --dry-run reflects mode ----------------------------
# Note: arg parsing only inspects $1; --dry-run alone shows daemon mode.
# --foreground alone needs a way to surface its plan — that's a known gap of
# the simple positional parser. Test only the positive case.
OUT_B2=$(GITHUB_EVENTS_PORT=9999 bash "$SCRIPT" --dry-run 2>&1)
assert_contains "B2: custom port reflected" "$OUT_B2" "9999"
assert_contains "B2: custom port in webhook url" "$OUT_B2" "127.0.0.1:9999/webhook"

# --- Case D: unknown argument exits 3 -----------------------------------------
OUT_D=$(bash "$SCRIPT" --bogus-flag 2>&1)
RC_D=$?
assert_exit "D: unknown arg exit 3" 3 "$RC_D"
assert_contains "D: unknown arg msg" "$OUT_D" "unknown argument"

# --- Case E: concurrent-invocation guard with live PID (--foreground) --------
# Foreground path exercises the lock-state matrix in acquire_lock_or_die.
# Use the test runner's own PID ($$) — guaranteed alive while we run.
# Lock-dir gating: simulate "watcher already running" by holding both the
# PID file AND the lock dir.
PID_FILE_E="$TEST_TMPDIR/live.pid"
LOCK_DIR_E="${PID_FILE_E}.lock"
printf '%s' "$$" >"$PID_FILE_E"
mkdir "$LOCK_DIR_E"
OUT_E=$(GITHUB_EVENTS_PID_FILE="$PID_FILE_E" bash "$SCRIPT" --foreground 2>&1)
RC_E=$?
assert_exit "E: already-running exit 0 (foreground)" 0 "$RC_E"
assert_contains "E: already-running message" "$OUT_E" "already running"
assert_file_exists "E: live PID file preserved" "$PID_FILE_E"
rm -rf "$LOCK_DIR_E"

# --- Case E2: daemon-mode pre-flight catches live PID -------------------------
# In default (daemon) mode the parent pre-flights the PID file before forking.
PID_FILE_E2="$TEST_TMPDIR/live2.pid"
printf '%s' "$$" >"$PID_FILE_E2"
OUT_E2=$(GITHUB_EVENTS_PID_FILE="$PID_FILE_E2" bash "$SCRIPT" 2>&1)
RC_E2=$?
assert_exit "E2: daemon already-running exit 0" 0 "$RC_E2"
assert_contains "E2: daemon already-running message" "$OUT_E2" "already running"
assert_file_exists "E2: live PID file preserved" "$PID_FILE_E2"

# --- Case F: stale PID file is detected and removed (--foreground) -----------
# 999999 is high enough to be unallocated on every supported platform; if it
# happens to be live, the test would mis-detect — accept the negligible risk.
# Use --foreground so the "Removing stale PID file" message appears on the
# parent's stderr (daemon mode redirects child stderr to the daemon log).
STATE_DIR_F="$TEST_TMPDIR/stale-state"
mkdir -p "$STATE_DIR_F"
PID_FILE_F="$TEST_TMPDIR/stale.pid"
printf '999999' >"$PID_FILE_F"
# SKIP_GH=1 (no SKIP_HEALTH, no PORT): the no-gh test mode must NOT auto-spawn a
# real broker (npm build) — with a fresh STATE_DIR there is no port file, so the
# script hits the SKIP_GH auto-spawn guard and exits BOUNDED right after the
# stale-PID reconciliation we assert on. The fresh STATE_DIR
# also keeps the reconciliation off the real LOCALAPPDATA/github-events.
OUT_F=$(
  GITHUB_EVENTS_PID_FILE="$PID_FILE_F" \
    GITHUB_EVENTS_STATE_DIR="$STATE_DIR_F" \
    GITHUB_EVENTS_SKIP_GH=1 \
    GITHUB_EVENTS_HEALTH_RETRIES=1 \
    bash "$SCRIPT" --foreground 2>&1
) || true
assert_contains "F: stale PID detected" "$OUT_F" "Removing stale PID file"
assert_contains "F: SKIP_GH bypasses real broker spawn (bounded)" "$OUT_F" "skipping auto-spawn"
assert_file_absent "F: stale PID file cleaned" "$PID_FILE_F"

# --- Case G: orphaned lock with dead owner is reclaimed (--foreground) -------
STATE_DIR_G="$TEST_TMPDIR/orphan-state"
mkdir -p "$STATE_DIR_G"
PID_FILE_G="$TEST_TMPDIR/orphan.pid"
LOCK_DIR_G="${PID_FILE_G}.lock"
printf '999999' >"$PID_FILE_G"
mkdir "$LOCK_DIR_G"
OUT_G=$(
  GITHUB_EVENTS_PID_FILE="$PID_FILE_G" \
    GITHUB_EVENTS_STATE_DIR="$STATE_DIR_G" \
    GITHUB_EVENTS_SKIP_GH=1 \
    GITHUB_EVENTS_HEALTH_RETRIES=1 \
    bash "$SCRIPT" --foreground 2>&1
) || true
assert_contains "G: orphaned lock detected" "$OUT_G" "Removing stale lock dir"
assert_file_absent "G: orphan PID file cleaned" "$PID_FILE_G"

# --- Case H: daemon mode end-to-end (SKIP_GH + SKIP_HEALTH) ------------------
# Exercise the full daemon parent→child fork → readiness sentinel → SIGTERM
# cleanup path. GITHUB_EVENTS_SKIP_HEALTH=1 + GITHUB_EVENTS_SKIP_GH=1 lets the
# child reach the test-mode block without spawning an HTTP listener — keeps
# this case fast + free of port-collision flakes under parallel runners.
# Verify: parent returns 0, PID file present, readiness sentinel present,
# child PID alive, daemon log written, SIGTERM triggers cleanup trap.
PID_FILE_H="$TEST_TMPDIR/daemon.pid"
DAEMON_LOG_H="$TEST_TMPDIR/daemon.log"
OUT_H=$(
  GITHUB_EVENTS_PID_FILE="$PID_FILE_H" \
    GITHUB_EVENTS_DAEMON_LOG="$DAEMON_LOG_H" \
    GITHUB_EVENTS_SKIP_GH=1 \
    GITHUB_EVENTS_SKIP_HEALTH=1 \
    GITHUB_EVENTS_READY_TIMEOUT=30 \
    bash "$SCRIPT" 2>&1
)
RC_H=$?
assert_exit "H: daemon parent exit 0" 0 "$RC_H"
assert_contains "H: parent reports daemon started" "$OUT_H" "Watcher daemon started"
assert_file_exists "H: PID file present" "$PID_FILE_H"
assert_file_exists "H: readiness sentinel present" "${PID_FILE_H}.ready"
assert_file_exists "H: daemon log written" "$DAEMON_LOG_H"

# Cleanup: SIGTERM daemon child, verify cleanup trap removes PID + ready.
DAEMON_PID_H=$(tr -d '\r\n[:space:]' <"$PID_FILE_H" 2>/dev/null || true)
if [[ -n "$DAEMON_PID_H" ]]; then
  kill_if_alive "$DAEMON_PID_H"
  # Wait briefly for trap to run.
  sleep 1
  assert_file_absent "H: PID file cleaned after SIGTERM" "$PID_FILE_H"
  assert_file_absent "H: readiness sentinel cleaned after SIGTERM" "${PID_FILE_H}.ready"
fi

# --- Case I: daemon mode no broker → readiness timeout -----------------------
# Without a /health stub and HEALTH_RETRIES=2 + READY_TIMEOUT=5, the child
# fails fast at health check; the parent's child-died path should fire and
# report non-zero. Tests the "child died before readiness" branch.
PID_FILE_I="$TEST_TMPDIR/nobroker.pid"
DAEMON_LOG_I="$TEST_TMPDIR/nobroker.log"
STATE_DIR_I="$TEST_TMPDIR/nobroker-state"
mkdir -p "$STATE_DIR_I"
# Pick a port that nothing is listening on.
DEAD_PORT=$(((RANDOM % 20000) + 50000))
OUT_I=$(
  GITHUB_EVENTS_PID_FILE="$PID_FILE_I" \
    GITHUB_EVENTS_DAEMON_LOG="$DAEMON_LOG_I" \
    GITHUB_EVENTS_STATE_DIR="$STATE_DIR_I" \
    GITHUB_EVENTS_PORT="$DEAD_PORT" \
    GITHUB_EVENTS_SKIP_GH=1 \
    GITHUB_EVENTS_HEALTH_RETRIES=2 \
    GITHUB_EVENTS_READY_TIMEOUT=10 \
    bash "$SCRIPT" 2>&1
)
RC_I=$?
if [[ "$RC_I" -ne 0 ]]; then
  pass "I: daemon parent exit non-zero when broker absent"
else
  fail "I: daemon parent exit non-zero when broker absent" "non-zero" "$RC_I"
fi
assert_contains "I: parent reports child died OR readiness timeout" "$OUT_I" "ERROR:"
assert_file_absent "I: no PID file on failure" "$PID_FILE_I"
assert_file_absent "I: no readiness sentinel on failure" "${PID_FILE_I}.ready"

# --- Case S: startup self-reconciliation prunes dead sibling broker files -----
# Boot the watcher in foreground test mode (SKIP_GH + SKIP_HEALTH) against a
# fresh STATE_DIR seeded with a DEAD-PID sibling broker file and a LIVE-PID one.
# The startup reconciliation runs after acquire_lock_or_die, before the
# test-mode sleep — so by the time the readiness sentinel appears, the dead
# broker file must be gone and the live one preserved. NEVER touches the real
# state dir — GITHUB_EVENTS_STATE_DIR points at a fresh mktemp dir.
STATE_DIR_S="$TEST_TMPDIR/reconcile-state"
mkdir -p "$STATE_DIR_S"
PID_FILE_S="$STATE_DIR_S/watcher.pid"
READY_FILE_S="${PID_FILE_S}.ready"
DAEMON_LOG_S="$TEST_TMPDIR/reconcile.log"
# Dead sibling broker (high unallocated PID) + companion ports file.
printf '999999\n' >"$STATE_DIR_S/broker-int-dead.pid"
printf '{"receiver":1,"broker":2}\n' >"$STATE_DIR_S/broker-int-dead.ports.json"
# Live sibling broker — a real backgrounded sleeper. The prune keeps it because
# the PID is alive (and, where ps cannot report args, conservatively kept).
sleep 30 &
LIVE_SIBLING_PID=$!
printf '%s\n' "$LIVE_SIBLING_PID" >"$STATE_DIR_S/broker-int-alive.pid"
printf '{"receiver":3,"broker":4}\n' >"$STATE_DIR_S/broker-int-alive.ports.json"

GITHUB_EVENTS_STATE_DIR="$STATE_DIR_S" \
  GITHUB_EVENTS_PID_FILE="$PID_FILE_S" \
  GITHUB_EVENTS_DAEMON_LOG="$DAEMON_LOG_S" \
  GITHUB_EVENTS_SKIP_GH=1 \
  GITHUB_EVENTS_SKIP_HEALTH=1 \
  bash "$SCRIPT" --foreground >"$DAEMON_LOG_S" 2>&1 &
WATCHER_FG_PID=$!

# Poll for the readiness sentinel (foreground test mode writes it before sleep).
s_i=0
while ((s_i < 30)); do
  [[ -f "$READY_FILE_S" ]] && break
  kill -0 "$WATCHER_FG_PID" 2>/dev/null || break
  sleep 1
  s_i=$((s_i + 1))
done

if [[ -f "$READY_FILE_S" ]]; then
  pass "S: watcher reached readiness in foreground test mode"
  assert_file_absent "S: dead sibling broker .pid pruned at startup" "$STATE_DIR_S/broker-int-dead.pid"
  assert_file_absent "S: dead sibling broker companion pruned at startup" "$STATE_DIR_S/broker-int-dead.ports.json"
  assert_file_exists "S: live sibling broker .pid preserved at startup" "$STATE_DIR_S/broker-int-alive.pid"
  assert_file_exists "S: live sibling broker companion preserved at startup" "$STATE_DIR_S/broker-int-alive.ports.json"
else
  fail "S: watcher reached readiness in foreground test mode" "ready sentinel present" "absent (log: $(tail -n 5 "$DAEMON_LOG_S" 2>/dev/null | tr '\n' '|'))"
fi

# Stop the watcher + reap the live sibling sleeper.
kill_if_alive "$WATCHER_FG_PID"
kill -TERM "$LIVE_SIBLING_PID" 2>/dev/null || true
wait "$LIVE_SIBLING_PID" 2>/dev/null || true

# --- Case V: winpid-aware liveness (W1-B / codex r3327743095) -----------------
# daemonize_parent, acquire_lock_or_die, and child-death poll must use
# pid::is_alive — bare kill -0 cannot see native gh.exe winpids on Git Bash.
if [[ "$SCRIPT_BODY" == *'pid-alive.sh'* ]]; then
  pass "V: watcher sources pid-alive.sh"
else
  fail "V: watcher sources pid-alive.sh" "present" "missing"
fi
if [[ "$SCRIPT_BODY" == *'pid::is_alive'* ]]; then
  pass "V: watcher uses pid::is_alive for liveness"
else
  fail "V: watcher uses pid::is_alive for liveness" "present" "missing"
fi
if grep -E 'kill -0' "$SCRIPT" | grep -qv '^[[:space:]]*#'; then
  fail "V: no bare kill -0 in watcher script body" "absent" "still present"
else
  pass "V: no bare kill -0 in watcher script body"
fi
if [[ "$SCRIPT_BODY" == *'ghe::kill_and_reap "$GH_PID"'* ]]; then
  pass "V: EXIT cleanup uses ghe::kill_and_reap for GH_PID"
else
  fail "V: EXIT cleanup uses ghe::kill_and_reap for GH_PID" "present" "missing"
fi

# --- Report -------------------------------------------------------------------

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d checks passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
