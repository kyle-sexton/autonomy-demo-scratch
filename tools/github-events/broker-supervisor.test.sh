#!/usr/bin/env bash
# Regression tests for tools/github-events/broker-supervisor.sh.
#
# The supervision loop could not be exercised through start-github-watcher.sh's
# black-box tests (they short-circuit via GITHUB_EVENTS_SKIP_GH before Step 5).
# This sources the lib directly and drives its functions with stubs:
#   - Fix A (codex 4392612369 L575): the healthy path must throttle, not
#     busy-loop. A1/A2 assert the interval sleep runs on every healthy iteration.
#   - Fix B (codex 4392612369 L585): a broker respawn on a new receiver port must
#     relaunch the forwarder against the new --url. B1/B2 assert restart-on-change
#     vs no-restart-on-same-port; B3/B4 exercise the real restart_forwarder
#     (re-subscription gate + PID-file publish).
#   - Case W: static cross-checks that the watcher wires the lib in.
#
# Ordered so the cases needing REAL kill/wait/grep (B3/B4/R5/R6) run BEFORE the
# broad stubs (kill/sleep/curl/...) are installed for the pure-logic cases.
#
# Sentinel duration: the `sleep 5 &` background jobs are killable stand-ins for a
# live forwarder PID — restart_forwarder kills each at entry. They are short (not
# 30s) because ghe::kill_and_reap waits on the killed PID, and on Git Bash/MSYS2 a
# SIGTERM to `sleep` is occasionally delayed, so a missed reap blocks `wait` for
# the FULL sleep duration. 5s caps that worst-case stall well under the test
# walltime hard cap (no case asserts the sentinel is alive — all expect it killed).
#
# Run: bash tools/github-events/broker-supervisor.test.sh
# Or:  bash tools/run-shell-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/broker-supervisor.sh"
WATCHER="$SCRIPT_DIR/start-github-watcher.sh"
TEST_TMPDIR="$(mktemp -d)"
# Guard the destructive cleanup to the main shell. The backgrounded `gh` stub
# (gh() { ...; } launched with &) runs in a subshell that inherits this EXIT
# trap; without the $BASHPID guard a subshell exit would rm -rf TEST_TMPDIR
# mid-test. $BASHPID differs from $$ in every subshell, so cleanup no-ops there.
_cleanup() {
  [[ "$BASHPID" == "$$" ]] || return 0
  rm -rf "$TEST_TMPDIR"
}
trap _cleanup EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# shellcheck source=./broker-supervisor.sh
source "$LIB"

# --- Case W: watcher wires the lib in (regression guards) ---------------------
WATCHER_BODY=$(cat "$WATCHER")
if [[ "$WATCHER_BODY" == *'broker-supervisor.sh'* ]]; then
  pass "W: watcher sources broker-supervisor.sh"
else
  fail "W: watcher sources broker-supervisor.sh" "present" "missing"
fi
if [[ "$WATCHER_BODY" == *'ghe::supervise_loop'* ]]; then
  pass "W: watcher calls ghe::supervise_loop"
else
  fail "W: watcher calls ghe::supervise_loop" "present" "missing"
fi
# Old inline subshell loop must be gone (its GH_PID update was invisible to the
# parent — the subshell-scoping bug that blocked Fix B).
if [[ "$WATCHER_BODY" != *'broker_health_loop'* ]]; then
  pass "W: old broker_health_loop function removed"
else
  fail "W: old broker_health_loop function removed" "absent" "still present"
fi
if [[ "$WATCHER_BODY" != *'HEALTH_LOOP_PID'* ]]; then
  pass "W: old HEALTH_LOOP_PID handle removed"
else
  fail "W: old HEALTH_LOOP_PID handle removed" "absent" "still present"
fi

# --- Case L: lib uses winpid-aware liveness, not bare kill -0 (codex r3327314231) -
# The forwarder ($GH_PID) is a native gh.exe on Windows whose PID bare `kill -0`
# cannot see; liveness must go through pid::is_alive (tasklist fallback) or the
# supervisor exits after the grace sleep while the forwarder is still running.
LIB_BODY=$(cat "$LIB")
if [[ "$LIB_BODY" == *'pid-alive.sh'* ]]; then
  pass "L: lib sources pid-alive.sh"
else
  fail "L: lib sources pid-alive.sh" "present" "missing"
fi
if [[ "$LIB_BODY" == *'pid::is_alive'* ]]; then
  pass "L: liveness check uses pid::is_alive"
else
  fail "L: liveness check uses pid::is_alive" "present" "missing"
fi
if [[ "$LIB_BODY" != *'! kill -0'* ]]; then
  pass "L: no bare-kill-0 liveness idiom remains (converted to pid::is_alive)"
else
  fail "L: no bare-kill-0 liveness idiom remains" "absent" "still present"
fi
if [[ "$LIB_BODY" == *'pid::is_alive "$pid"'* ]]; then
  pass "L: kill_and_reap consults pid::is_alive"
else
  fail "L: kill_and_reap consults pid::is_alive" "present" "missing"
fi
if [[ "$LIB_BODY" == *'taskkill'* ]]; then
  pass "L: kill_and_reap has Windows taskkill fallback"
else
  fail "L: kill_and_reap has Windows taskkill fallback" "present" "missing"
fi
# Guarded reap (codex r3327525980): never `wait` on an unkillable native pid.
if [[ "$LIB_BODY" == *'ghe::kill_and_reap'* ]]; then
  pass "L: forwarder teardown uses guarded ghe::kill_and_reap (no blocking wait)"
else
  fail "L: forwarder teardown uses guarded ghe::kill_and_reap" "present" "missing"
fi

# --- Case B3: restart_forwarder relaunches + publishes new PID on success -----
# Real kill/wait/grep; stub only gh (writes a subscription line + lingers) + tail.
# restart_forwarder now reconciles first (ghe::ensure_no_stale_cli_hook → gh api);
# the stub returns an empty hook list for `gh api` so the reconcile is a clean
# no-op and the forwarder branch behaves as before.
gh() {
  [[ "$1" == "api" ]] && return 0 # reconcile list (empty) / delete — no-op
  printf 'Forwarding events to %s\n' "$WEBHOOK_URL"
  sleep 3
}
tail() { :; }

REPO="o/r"
EVENTS="*"
WEBHOOK_URL="http://127.0.0.1:2222/webhook"
SUBSCRIBE_RETRIES=5
PID_FILE="$TEST_TMPDIR/b3.pid"
GH_LOG="$(mktemp)"
TAIL_PID=""
sleep 5 &
GH_PID=$!
OLD_GH_PID="$GH_PID"

ghe::restart_forwarder
RC_B3=$?
assert_exit "B3: restart_forwarder returns 0 on confirmed re-subscription" 0 "$RC_B3"
NEW_PID="$(tr -d '\r\n[:space:]' <"$PID_FILE" 2>/dev/null || true)"
assert_eq "B3: PID file holds the new forwarder PID" "$GH_PID" "$NEW_PID"
if [[ "$NEW_PID" != "$OLD_GH_PID" ]]; then
  pass "B3: forwarder PID changed (old torn down)"
else
  fail "B3: forwarder PID changed" "new != old" "both $NEW_PID"
fi
if ! kill -0 "$OLD_GH_PID" 2>/dev/null; then
  pass "B3: old forwarder process killed"
else
  fail "B3: old forwarder process killed" "dead" "still alive"
fi
# Reap the new gh-stub so it does not leak past the test.
kill "$GH_PID" 2>/dev/null || true
wait "$GH_PID" 2>/dev/null || true
rm -f "${GH_LOG:-}"

# --- Case B4: restart_forwarder fails closed when re-subscription never lands --
# gh-stub never writes a subscription line and stays alive → wait times out.
# PID file must NOT be advanced (fails to the Monitor fallback, not silently up).
# `gh api` (reconcile) returns an empty list so the failure under test is the
# re-subscription timeout, not the reconcile.
gh() {
  [[ "$1" == "api" ]] && return 0
  sleep 3
}
tail() { :; }

WEBHOOK_URL="http://127.0.0.1:3333/webhook"
SUBSCRIBE_RETRIES=2
PID_FILE="$TEST_TMPDIR/b4.pid"
printf 'OLDPID' >"$PID_FILE"
GH_LOG="$(mktemp)"
TAIL_PID=""
sleep 5 &
GH_PID=$!

ghe::restart_forwarder
RC_B4=$?
assert_exit "B4: restart_forwarder returns 1 when re-subscription times out" 1 "$RC_B4"
assert_eq "B4: PID file NOT advanced on re-subscription failure" "OLDPID" "$(cat "$PID_FILE" 2>/dev/null || true)"
if ! kill -0 "$GH_PID" 2>/dev/null; then
  pass "B4: unsubscribed forwarder torn down"
else
  fail "B4: unsubscribed forwarder torn down" "dead" "still alive"
  kill "$GH_PID" 2>/dev/null || true
fi
rm -f "${GH_LOG:-}"
unset -f gh tail

# --- Reconcile cases: ghe::ensure_no_stale_cli_hook ---------------------------
# The reconcile deletes pre-existing `gh webhook forward` relay hooks before a
# launch so the forwarder never hits "422 Hook already exists". The production
# discriminator keys on .config.url containing the relay endpoint, NOT .name.
#
# To actually EXERCISE that production --jq filter (rather than bypass it with
# pre-filtered stub output — the structural hole a name-keyed stub would hide),
# the `gh api` LIST stub extracts the real --jq expression the production code
# passes and applies it to canned RAW hook JSON via system jq. So R1 proves the
# live-verified filter both selects the relay hook AND spares an unrelated one.
REPO="o/r"
GH_CALLS="$TEST_TMPDIR/reconcile-gh-calls.txt"
STUB_HOOK_JSON='[]'
STUB_LIST_RC=0
gh() {
  printf '%s\n' "$*" >>"$GH_CALLS"
  if [[ "$1" == "api" && "$*" != *DELETE* ]]; then
    local i jq_expr=""
    local -a a=("$@")
    for ((i = 0; i < ${#a[@]}; i++)); do
      [[ "${a[i]}" == "--jq" ]] && {
        jq_expr="${a[i + 1]}"
        break
      }
    done
    [[ -n "$jq_expr" ]] && printf '%s' "$STUB_HOOK_JSON" | jq -r "$jq_expr"
    return "$STUB_LIST_RC"
  fi
  return 0 # DELETE path
}

# R4 (jq-independent): SKIP_GH bypasses reconcile entirely — no gh call at all.
: >"$GH_CALLS"
GITHUB_EVENTS_SKIP_GH=1 ghe::ensure_no_stale_cli_hook
RC_R4=$?
assert_exit "R4: reconcile returns 0 under GITHUB_EVENTS_SKIP_GH=1" 0 "$RC_R4"
assert_silent "R4: no gh call under SKIP_GH (test mode)" "$(cat "$GH_CALLS")"

if ! command -v jq >/dev/null 2>&1; then
  skip_case "jq unavailable — reconcile filter cases need system jq to simulate gh --jq"
else
  # R1: production filter selects the relay hook (111), spares the unrelated one (222).
  STUB_HOOK_JSON='[{"id":111,"name":"cli","config":{"url":"https://webhook-forwarder.github.com/hook"},"events":["*"]},{"id":222,"name":"web","config":{"url":"https://example.com/ci"},"events":["push"]}]'
  STUB_LIST_RC=0
  : >"$GH_CALLS"
  ghe::ensure_no_stale_cli_hook
  assert_exit "R1: reconcile returns 0 on success" 0 "$?"
  if grep -q 'DELETE repos/o/r/hooks/111' "$GH_CALLS"; then
    pass "R1: deletes the relay-endpoint hook (id 111)"
  else
    fail "R1: deletes the relay-endpoint hook" "DELETE .../111" "$(cat "$GH_CALLS")"
  fi
  if ! grep -q 'hooks/222' "$GH_CALLS"; then
    pass "R1: spares the unrelated webhook (id 222 not deleted)"
  else
    fail "R1: spares the unrelated webhook" "no DELETE .../222" "$(cat "$GH_CALLS")"
  fi

  # R2: no relay hook present → no DELETE, returns 0 (idempotent clean slate).
  STUB_HOOK_JSON='[{"id":222,"name":"web","config":{"url":"https://example.com/ci"},"events":["push"]}]'
  : >"$GH_CALLS"
  ghe::ensure_no_stale_cli_hook
  assert_exit "R2: returns 0 when no relay hook present" 0 "$?"
  if ! grep -q DELETE "$GH_CALLS"; then
    pass "R2: no DELETE when nothing to reconcile"
  else
    fail "R2: no DELETE when nothing to reconcile" "no DELETE" "$(cat "$GH_CALLS")"
  fi

  # R3: list failure (e.g. missing admin:repo_hook scope) → returns 1, actionable,
  # and NO DELETE attempted (cause surfaced, not swallowed behind the 422).
  STUB_HOOK_JSON='[]'
  STUB_LIST_RC=1
  : >"$GH_CALLS"
  OUT_R3=$(ghe::ensure_no_stale_cli_hook 2>&1)
  RC_R3=$?
  STUB_LIST_RC=0
  assert_exit "R3: reconcile returns 1 on gh api list failure" 1 "$RC_R3"
  assert_contains "R3: actionable error names admin:repo_hook scope" "$OUT_R3" "admin:repo_hook"
  if ! grep -q DELETE "$GH_CALLS"; then
    pass "R3: no DELETE attempted after a failed list"
  else
    fail "R3: no DELETE attempted after a failed list" "no DELETE" "$(cat "$GH_CALLS")"
  fi
fi
unset -f gh

# --- Case R5: restart_forwarder reconciles BEFORE launching the forwarder -----
# Real kill/wait; gh stub records calls so ordering is observable. The reconcile
# (gh api) runs synchronously before `gh webhook forward` is backgrounded, so the
# FIRST recorded gh call must be the api (reconcile) call.
RC_CALLS="$TEST_TMPDIR/r5-gh-calls.txt"
gh() {
  printf '%s\n' "$*" >>"$RC_CALLS"
  [[ "$1" == "api" ]] && return 0     # reconcile: empty list / delete
  printf 'subscription established\n' # forward stdout → GH_LOG via caller redirect
  sleep 3
}
tail() { :; }
REPO="o/r"
EVENTS="*"
WEBHOOK_URL="http://127.0.0.1:4444/webhook"
SUBSCRIBE_RETRIES=5
PID_FILE="$TEST_TMPDIR/r5.pid"
GH_LOG="$(mktemp)"
TAIL_PID=""
sleep 5 &
GH_PID=$!
: >"$RC_CALLS"
ghe::restart_forwarder
RC_R5=$?
assert_exit "R5: restart_forwarder returns 0 (reconcile + re-subscribe)" 0 "$RC_R5"
if [[ "$(head -1 "$RC_CALLS")" == api* ]]; then
  pass "R5: reconcile (gh api) runs before the forwarder launch"
else
  fail "R5: reconcile runs before the forwarder launch" "api ... first" "$(head -1 "$RC_CALLS")"
fi
if grep -q 'webhook forward' "$RC_CALLS"; then
  pass "R5: forwarder launched after reconcile"
else
  fail "R5: forwarder launched after reconcile" "webhook forward present" "$(cat "$RC_CALLS")"
fi
kill "$GH_PID" 2>/dev/null || true
wait "$GH_PID" 2>/dev/null || true
rm -f "${GH_LOG:-}"

# --- Case R6: a failed reconcile aborts the relaunch (fail-closed) ------------
# gh api (reconcile list) fails → restart_forwarder returns 1 WITHOUT launching
# the forwarder and WITHOUT advancing the PID file (falls to Monitor fallback).
gh() {
  printf '%s\n' "$*" >>"$RC_CALLS"
  [[ "$1" == "api" ]] && return 1 # reconcile list fails (e.g. scope)
  printf 'subscription established\n'
  sleep 3
}
tail() { :; }
WEBHOOK_URL="http://127.0.0.1:5555/webhook"
PID_FILE="$TEST_TMPDIR/r6.pid"
printf 'OLDPID' >"$PID_FILE"
GH_LOG="$(mktemp)"
TAIL_PID=""
sleep 5 &
GH_PID=$!
: >"$RC_CALLS"
ghe::restart_forwarder >/dev/null 2>&1
RC_R6=$?
assert_exit "R6: restart_forwarder returns 1 when reconcile fails" 1 "$RC_R6"
if ! grep -q 'webhook forward' "$RC_CALLS"; then
  pass "R6: forwarder NOT launched when reconcile fails (fail-closed)"
else
  fail "R6: forwarder NOT launched when reconcile fails" "no forward" "$(cat "$RC_CALLS")"
fi
assert_eq "R6: PID file not advanced on reconcile failure" "OLDPID" "$(cat "$PID_FILE" 2>/dev/null || true)"
kill "$GH_PID" 2>/dev/null || true
wait "$GH_PID" 2>/dev/null || true
rm -f "${GH_LOG:-}"
unset -f gh tail

# --- Broad stubs for the pure-logic cases -------------------------------------
# From here, no real processes: kill -0 always "alive", sleep/date/curl/spawn are
# recorded/forced, and restart_forwarder is a recorder so B1/B2 observe only the
# CALL decision (its real behavior is covered by B3/B4 above).
SLEEP_LOG="$TEST_TMPDIR/sleeps.txt"
RESTART_LOG="$TEST_TMPDIR/restarts.txt"
CURL_RC=0
sleep() { printf '%s\n' "${1:-}" >>"$SLEEP_LOG"; }
date() { printf '1000\n'; }
kill() { return 0; }
curl() { return "$CURL_RC"; }
ghe::restart_forwarder() {
  printf 'restart url=%s\n' "$WEBHOOK_URL" >>"$RESTART_LOG"
  return 0
}

# --- Case B1: broker respawn on a NEW port relaunches the forwarder -----------
CURL_RC=1 # broker unhealthy → respawn path
HEALTH_URL="http://127.0.0.1:1111/health"
WEBHOOK_URL="http://127.0.0.1:1111/webhook"
PORT=1111
BROKER_PORT=11110
GHE_BACKOFF=1
GHE_LAST_RESTART=0
BROKER_BACKOFF_MAX=30
BROKER_STABLE_RESET=300
spawn_broker() {
  PORT=2222
  BROKER_PORT=22220
  HEALTH_URL="http://127.0.0.1:2222/health"
  WEBHOOK_URL="http://127.0.0.1:2222/webhook"
  return 0
}
: >"$RESTART_LOG"
ghe::supervise_step
if grep -q 'restart url=http://127.0.0.1:2222/webhook' "$RESTART_LOG"; then
  pass "B1: forwarder relaunched against new URL on broker port change"
else
  fail "B1: forwarder relaunched on broker port change" "restart with new url" "$(cat "$RESTART_LOG")"
fi

# --- Case B2: broker respawn on the SAME port does NOT relaunch the forwarder -
CURL_RC=1
HEALTH_URL="http://127.0.0.1:1111/health"
WEBHOOK_URL="http://127.0.0.1:1111/webhook"
PORT=1111
BROKER_PORT=11110
GHE_BACKOFF=1
GHE_LAST_RESTART=0
spawn_broker() {
  PORT=1111
  BROKER_PORT=11110
  HEALTH_URL="http://127.0.0.1:1111/health"
  WEBHOOK_URL="http://127.0.0.1:1111/webhook"
  return 0
}
: >"$RESTART_LOG"
ghe::supervise_step
if [[ ! -s "$RESTART_LOG" ]]; then
  pass "B2: forwarder NOT relaunched when receiver port unchanged"
else
  fail "B2: forwarder NOT relaunched when port unchanged" "no restart" "$(cat "$RESTART_LOG")"
fi

# --- Case B5: supervise_step propagates a failed forwarder relaunch ----------
# codex r3327000120: a relaunch that never re-subscribes must NOT be swallowed —
# the step returns non-zero so the loop can exit and the EXIT trap cleans up now.
ghe::restart_forwarder() {
  printf 'restart-fail url=%s\n' "$WEBHOOK_URL" >>"$RESTART_LOG"
  return 1
}
CURL_RC=1
HEALTH_URL="http://127.0.0.1:1111/health"
WEBHOOK_URL="http://127.0.0.1:1111/webhook"
PORT=1111
BROKER_PORT=11110
GHE_BACKOFF=1
GHE_LAST_RESTART=0
spawn_broker() {
  PORT=2222
  BROKER_PORT=22220
  HEALTH_URL="http://127.0.0.1:2222/health"
  WEBHOOK_URL="http://127.0.0.1:2222/webhook"
  return 0
}
ghe::supervise_step
RC_B5=$?
assert_exit "B5: supervise_step returns non-zero when a relaunch fails to re-subscribe" 1 "$RC_B5"

# --- Case B6: supervise_loop exits immediately on a failed relaunch ----------
# No full-interval sleep with a dead forwarder + stale PID file — the loop
# returns so the caller reaps and the EXIT trap clears state now. Reuses the
# B5 stubs (restart_forwarder → 1, spawn_broker → port change).
GH_PID=4242
BROKER_HEALTH_INTERVAL=30
BROKER_BACKOFF_MAX=30
BROKER_STABLE_RESET=300
GHE_SUPERVISE_MAX_ITERS=5
CURL_RC=1
HEALTH_URL="http://127.0.0.1:1111/health"
WEBHOOK_URL="http://127.0.0.1:1111/webhook"
PORT=1111
BROKER_PORT=11110
: >"$SLEEP_LOG"
ghe::supervise_loop
RC_B6=$?
assert_exit "B6: supervise_loop returns 0 when a relaunch fails unrecoverably" 0 "$RC_B6"
if ! grep -qx '30' "$SLEEP_LOG"; then
  pass "B6: loop exits before the interval sleep (no full-interval wait with dead forwarder)"
else
  fail "B6: loop exits before the interval sleep" "no interval sleep recorded" "$(tr '\n' ',' <"$SLEEP_LOG")"
fi

# --- Case B7: respawn removes the stale port file before spawn_broker ---------
# An uncleanly-dead broker leaves broker-*.ports.json behind; if it is not removed
# first, spawn_broker → discover_ports reads the OLD ports and the forwarder is
# never relaunched (codex r3327878325). spawn_broker records whether the file was
# still present when it ran.
PORT_FILE="$TEST_TMPDIR/stale-ports.json"
printf '{"receiver":1111,"broker":11110}\n' >"$PORT_FILE"
PORTFILE_AT_SPAWN="$TEST_TMPDIR/portfile-state.txt"
CURL_RC=1
HEALTH_URL="http://127.0.0.1:1111/health"
WEBHOOK_URL="http://127.0.0.1:1111/webhook"
PORT=1111
BROKER_PORT=11110
GHE_BACKOFF=1
GHE_LAST_RESTART=0
ghe::restart_forwarder() { return 0; }
spawn_broker() {
  if [[ -f "$PORT_FILE" ]]; then printf 'present\n' >"$PORTFILE_AT_SPAWN"; else printf 'removed\n' >"$PORTFILE_AT_SPAWN"; fi
  PORT=2222
  BROKER_PORT=22220
  HEALTH_URL="http://127.0.0.1:2222/health"
  WEBHOOK_URL="http://127.0.0.1:2222/webhook"
  return 0
}
ghe::supervise_step
assert_eq "B7: stale port file removed before spawn_broker" "removed" "$(cat "$PORTFILE_AT_SPAWN" 2>/dev/null || true)"

# --- Case A1: healthy probe still throttles (no busy-loop) --------------------
CURL_RC=0 # broker healthy
HEALTH_URL="http://127.0.0.1:1111/health"
GH_PID=4242 # fake; kill stub reports alive
BROKER_HEALTH_INTERVAL=30
GHE_SUPERVISE_MAX_ITERS=1
: >"$SLEEP_LOG"
ghe::supervise_loop
if grep -qx '30' "$SLEEP_LOG"; then
  pass "A1: healthy iteration sleeps the health interval (no busy-loop)"
else
  fail "A1: healthy iteration sleeps the health interval" "30 present" "$(tr '\n' ',' <"$SLEEP_LOG")"
fi

# --- Case A2: every healthy iteration throttles -------------------------------
CURL_RC=0
HEALTH_URL="http://127.0.0.1:1111/health"
GH_PID=4242
BROKER_HEALTH_INTERVAL=30
GHE_SUPERVISE_MAX_ITERS=3
: >"$SLEEP_LOG"
ghe::supervise_loop
INTERVAL_SLEEPS="$(grep -cx '30' "$SLEEP_LOG" || true)"
assert_eq "A2: 3 healthy iterations → 3 interval sleeps" "3" "$INTERVAL_SLEEPS"

# --- Report -------------------------------------------------------------------
if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d checks passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
