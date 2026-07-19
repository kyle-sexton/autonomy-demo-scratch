#!/usr/bin/env bash
# Regression tests for tools/shared/process-management/pid-graceful-stop.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"
# shellcheck source=./pid-graceful-stop.sh
source "$SCRIPT_DIR/pid-graceful-stop.sh"

# Spawn a long-running sleep, return its PID. Caller is responsible for
# ensuring it dies (via the helper, or via a fallback `kill -KILL` in trap).
#
# The backgrounded child's stdout/stderr are redirected to /dev/null on
# purpose. spawn_target is called as `PID=$(spawn_target ...)`, and command
# substitution reads the captured fd1 pipe until every writer closes it. A
# backgrounded child inherits that pipe fd, so without the redirect the
# substitution blocks until the child's `sleep 30` ends (~30s of near-zero-CPU
# stall) — which froze the pre-push shell-test-walltime lane. The redirect
# keeps the child off the capture pipe, so only `echo "$pid"` writes to it and
# the substitution returns immediately.
spawn_target() {
  local trap_handler="${1:-}" pid
  if [[ -n "$trap_handler" ]]; then
    bash -c "trap '$trap_handler' TERM INT; sleep 30 & wait" >/dev/null 2>&1 &
    pid=$!
    # Let the trap install before the caller signals. The prior pipe-inheritance
    # stall incidentally guaranteed this; removing it (the redirect) brings the
    # race back, so re-establish the delay explicitly (mirrors Case 2 below).
    sleep 0.1
  else
    sleep 30 >/dev/null 2>&1 &
    pid=$!
  fi
  echo "$pid"
}

cleanup_pids=()
# shellcheck disable=SC2154  # `p` is the loop variable inside the trap body
trap 'for p in "${cleanup_pids[@]}"; do kill -KILL "$p" 2>/dev/null || true; done; rm -rf "$TEST_TMPDIR"' EXIT

# --- Case 1: process exits on first signal (SIGTERM honored) ---
PID1=$(spawn_target "exit 0")
cleanup_pids+=("$PID1")
pid::graceful_stop "$PID1" TERM 10 0.1
RC=$?
assert_exit "case 1: clean exit on SIGTERM" 0 "$RC"
if kill -0 "$PID1" 2>/dev/null; then
  fail "case 1: PID still alive" "dead" "alive"
else
  pass "case 1: PID confirmed dead"
fi

# --- Case 2: process ignores SIGTERM, escalation to SIGKILL needed ---
# `trap '' TERM` sets the signal to IGNORED in the kernel — SIGTERM is
# discarded without reaching the bash process. SIGKILL (uncatchable) still
# terminates it via the helper's escalation path.
bash -c "trap '' TERM; sleep 60" &
PID2=$!
cleanup_pids+=("$PID2")
sleep 0.1 # let trap install before signaling
pid::graceful_stop "$PID2" TERM 3 0.1
RC=$?
assert_exit "case 2: escalation to SIGKILL" 1 "$RC"
if kill -0 "$PID2" 2>/dev/null; then
  fail "case 2: PID still alive after SIGKILL" "dead" "alive"
else
  pass "case 2: PID dead after SIGKILL escalation"
fi

# --- Case 3: SIGINT first-signal variant (broker shape) ---
# graceful_stop with INT as the first signal must STOP the process. On Linux
# `kill -INT` reaches the backgrounded fixture's trap → clean exit (rc 0). On
# Git Bash/MSYS2, `kill -INT` is not reliably delivered to a non-foreground
# process (SIGINT is terminal-oriented — verified empirically: TERM kills the
# fixture, INT does not), so graceful_stop escalates to SIGKILL (rc 1). Both
# leave the process dead, which is the contract (rc 2 = escalation FAILED is the
# real failure). Accept rc 0 or 1 and assert the process is gone. (The prior
# 30s pipe-inheritance stall masked this — the fixture self-exited before
# graceful_stop ran, so Case 3 never actually exercised the INT path.)
PID3=$(spawn_target "exit 0")
cleanup_pids+=("$PID3")
pid::graceful_stop "$PID3" INT 10 0.1
RC=$?
if [[ "$RC" -eq 0 || "$RC" -eq 1 ]]; then
  pass "case 3: INT-first graceful_stop stopped the process (rc=$RC)"
else
  fail "case 3: INT-first graceful_stop did not stop process" "rc 0 or 1" "rc $RC"
fi
if kill -0 "$PID3" 2>/dev/null; then
  fail "case 3: PID still alive after INT-first graceful_stop" "dead" "alive"
else
  pass "case 3: PID confirmed dead after INT-first graceful_stop"
fi

# --- Case 4: already-dead PID exits immediately with code 0 ---
PID4=$(spawn_target "")
kill -KILL "$PID4" 2>/dev/null || true
sleep 0.2
pid::graceful_stop "$PID4" TERM 3 0.1
RC=$?
assert_exit "case 4: already-dead → 0" 0 "$RC"

# --- Case 5: post-signal exit polls are winpid-aware (codex r3327743095) ---
# On Git Bash/Windows a native gh.exe/Node PID is invisible to bare `kill -0`;
# the polls must use pid::is_alive (tasklist fallback) or graceful_stop returns
# "exited cleanly" for a process that is still running.
SUT_BODY=$(cat "$SCRIPT_DIR/pid-graceful-stop.sh")
if [[ "$SUT_BODY" == *'pid::is_alive'* ]]; then
  pass "case 5: exit polls use pid::is_alive (winpid-aware)"
else
  fail "case 5: exit polls use pid::is_alive" "present" "missing"
fi

# --- Case 6: regression guard — spawn_target must not block on the $() pipe ---
# A backgrounded child inheriting the command-substitution fd1 made
# PID=$(spawn_target ...) stall ~30s (until the child's `sleep` ended) at
# near-zero CPU, which froze the pre-push shell-test-walltime lane. The bg
# child's streams are now redirected off the capture pipe, so the substitution
# returns at once. Assert it returns far under the per-call `sleep 30` so a
# reintroduced inheritance FAILS here instead of silently stalling the suite.
G_START=$EPOCHREALTIME
PID6=$(spawn_target "exit 0")
G_END=$EPOCHREALTIME
cleanup_pids+=("$PID6")
G_MS=$(awk -v s="$G_START" -v e="$G_END" 'BEGIN{printf "%d", (e - s) * 1000}')
if [[ "$G_MS" -lt 2000 ]]; then
  pass "case 6: spawn_target returns promptly (${G_MS}ms, no \$() pipe-inheritance stall)"
else
  fail "case 6: spawn_target blocked (\$() pipe-inheritance regressed)" "<2000ms" "${G_MS}ms"
fi

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
