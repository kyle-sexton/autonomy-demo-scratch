#!/usr/bin/env bash
# Regression tests for tools/github-events/stop-github-watcher.sh.
#
# Coverage:
#   - no PID file → "not running" message, exit 0
#   - empty PID file → removes file, exit 0 (idempotent cleanup)
#   - stale PID (no live process) → removes file, exit 0 (idempotent cleanup)
#   - live PID → SIGTERM, process exits, PID file removed, exit 0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/stop-github-watcher.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"; pkill -P $$ 2>/dev/null || true' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

run_with_pidfile() {
  local pidfile="$1"
  # Isolate STATE_DIR + slug so the broker-stop half resolves to an empty
  # fixture dir, never the real ${LOCALAPPDATA}/github-events broker pid —
  # otherwise these cases attempt to stop a live shared broker (matches the
  # run_stop_owncheck isolation below).
  GITHUB_EVENTS_PID_FILE="$pidfile" GITHUB_EVENTS_STATE_DIR="$TEST_TMPDIR" GITHUB_EVENTS_REPO_SLUG="test" \
    GITHUB_EVENTS_SKIP_OWNERSHIP_CHECK=1 STOP_TIMEOUT=2 bash "$SCRIPT" 2>&1
}

# Stub `ps` on PATH so the ownership identity check sees a controlled args
# string (STUB_PS_ARGS) — lets the Windows gh.exe / backslash forms be exercised
# deterministically without a real native process. Liveness (pid::is_alive) uses
# kill -0, not ps, so the stub does not affect it.
STUB_BIN="$TEST_TMPDIR/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/ps" <<'PS'
#!/usr/bin/env bash
printf '%s\n' "${STUB_PS_ARGS:-}"
exit 0
PS
chmod +x "$STUB_BIN/ps"

# run_stop_owncheck <pidfile> <state_dir> — run stop WITH the ownership check
# active (no SKIP) and the stubbed `ps` on PATH.
run_stop_owncheck() {
  PATH="$STUB_BIN:$PATH" \
    GITHUB_EVENTS_PID_FILE="$1" \
    GITHUB_EVENTS_STATE_DIR="$2" \
    GITHUB_EVENTS_REPO_SLUG="test" \
    STOP_TIMEOUT=2 bash "$SCRIPT" 2>&1
}

# --- Case 1: no PID file → "not running" ---
PIDFILE="$TEST_TMPDIR/missing.pid"
OUT=$(run_with_pidfile "$PIDFILE")
RC=$?
assert_exit "no PID file → exit 0" 0 "$RC"
assert_contains "no PID file → 'not running' message" "$OUT" "not running"

# --- Case 2: empty PID file → removed, exit 0 (idempotent cleanup) ---
PIDFILE="$TEST_TMPDIR/empty.pid"
: >"$PIDFILE"
OUT=$(run_with_pidfile "$PIDFILE")
RC=$?
assert_exit "empty PID → exit 0" 0 "$RC"
assert_contains "empty PID → cleanup message" "$OUT" "PID file empty"
assert_file_absent "empty PID file removed" "$PIDFILE"

# --- Case 3: stale PID (highly unlikely-live PID number) → removed, exit 0 ---
PIDFILE="$TEST_TMPDIR/stale.pid"
echo "9999999" >"$PIDFILE"
OUT=$(run_with_pidfile "$PIDFILE")
RC=$?
assert_exit "stale PID → exit 0" 0 "$RC"
assert_contains "stale PID → 'already dead' message" "$OUT" "already dead"
assert_file_absent "stale PID file removed" "$PIDFILE"

# --- Case 4: live PID → SIGTERM kills it, file removed, exit 0 ---
PIDFILE="$TEST_TMPDIR/live.pid"
# Sleep long enough for the stop script's SIGTERM round-trip but short
# enough not to hang on test failure. STOP_TIMEOUT=2 gives 2 attempts.
sleep 30 &
LIVE_PID=$!
echo "$LIVE_PID" >"$PIDFILE"

OUT=$(run_with_pidfile "$PIDFILE")
RC=$?
assert_exit "live PID + SIGTERM → exit 0" 0 "$RC"
assert_contains "live PID → 'stopped cleanly' message" "$OUT" "stopped cleanly"
assert_file_absent "live PID file removed" "$PIDFILE"

# Wait briefly to reap the sleep child, ignore status.
wait "$LIVE_PID" 2>/dev/null || true

# --- Case 5: --help mentions --prune-orphans ---
HELP_OUT=$(bash "$SCRIPT" --help 2>&1)
assert_exit "--help exit 0" 0 "$?"
assert_contains "--help documents --prune-orphans" "$HELP_OUT" "--prune-orphans"

# --- Case 6: unknown argument exits 3 ---
bash "$SCRIPT" --bogus-flag >/dev/null 2>&1
assert_exit "unknown arg exit 3" 3 "$?"

# All --prune-orphans cases drive a fresh STATE_DIR via GITHUB_EVENTS_STATE_DIR
# so the prune NEVER touches the real LOCALAPPDATA/github-events. SKIP_OWNERSHIP
# disables the ps identity match (no live broker spawned) → dead-PID path only.
run_prune() {
  local state_dir="$1"
  GITHUB_EVENTS_STATE_DIR="$state_dir" GITHUB_EVENTS_SKIP_OWNERSHIP_CHECK=1 \
    bash "$SCRIPT" --prune-orphans 2>&1
}

# --- Case 7: --prune-orphans removes a dead-PID sibling broker file ---
PRUNE_SD_A="$TEST_TMPDIR/prune-dead"
mkdir -p "$PRUNE_SD_A"
printf '999999\n' >"$PRUNE_SD_A/broker-int-aaa.pid"
printf '{"receiver":58620,"broker":58621}\n' >"$PRUNE_SD_A/broker-int-aaa.ports.json"
OUT=$(run_prune "$PRUNE_SD_A")
RC=$?
assert_exit "--prune-orphans exit 0 (dead)" 0 "$RC"
assert_contains "--prune-orphans reports completion" "$OUT" "Orphan-broker prune complete"
assert_file_absent "--prune-orphans removed dead .pid" "$PRUNE_SD_A/broker-int-aaa.pid"
assert_file_absent "--prune-orphans removed dead companion .ports.json" "$PRUNE_SD_A/broker-int-aaa.ports.json"

# --- Case 8: --prune-orphans does NOT remove a LIVE-PID sibling broker file ---
# Per locked design test (b): a live PID must NOT be pruned by the dead-PID
# path. With SKIP_OWNERSHIP (no pattern) the prune keeps any live PID even when
# its args do not match the broker entry.
PRUNE_SD_B="$TEST_TMPDIR/prune-live"
mkdir -p "$PRUNE_SD_B"
sleep 30 &
LIVE_BROKER_PID=$!
printf '%s\n' "$LIVE_BROKER_PID" >"$PRUNE_SD_B/broker-int-bbb.pid"
printf '{"receiver":58622,"broker":58623}\n' >"$PRUNE_SD_B/broker-int-bbb.ports.json"
OUT=$(run_prune "$PRUNE_SD_B")
RC=$?
assert_exit "--prune-orphans exit 0 (live)" 0 "$RC"
assert_file_exists "--prune-orphans kept live .pid" "$PRUNE_SD_B/broker-int-bbb.pid"
assert_file_exists "--prune-orphans kept live companion .ports.json" "$PRUNE_SD_B/broker-int-bbb.ports.json"
kill -TERM "$LIVE_BROKER_PID" 2>/dev/null || true
wait "$LIVE_BROKER_PID" 2>/dev/null || true

# --- Case 9: --prune-orphans on empty/missing state dir is a no-op, exit 0 ---
PRUNE_SD_C="$TEST_TMPDIR/prune-empty"
mkdir -p "$PRUNE_SD_C"
OUT=$(run_prune "$PRUNE_SD_C")
RC=$?
assert_exit "--prune-orphans exit 0 (empty dir)" 0 "$RC"
assert_contains "--prune-orphans completion on empty dir" "$OUT" "Orphan-broker prune complete"

# --- Case 11: live native gh.exe watcher accepted + signaled (codex r3327793626) -
# ps reports the Windows form `...\gh.exe webhook forward`; the ownership check
# must normalize + match it, then stop the live process — NOT remove its PID
# file as "stale" while leaving it running.
SD11="$TEST_TMPDIR/own-ghexe"
mkdir -p "$SD11"
PIDFILE11="$TEST_TMPDIR/own-ghexe.pid"
sleep 30 &
GHEXE_PID=$!
echo "$GHEXE_PID" >"$PIDFILE11"
OUT=$(STUB_PS_ARGS='C:\Program Files\GitHub CLI\gh.exe webhook forward --url=http://127.0.0.1:8788/webhook' run_stop_owncheck "$PIDFILE11" "$SD11")
assert_contains "case 11: gh.exe watcher signaled (stopped cleanly)" "$OUT" "stopped cleanly"
assert_not_contains "case 11: not treated as stale" "$OUT" "stale file, removing"
assert_file_absent "case 11: PID file removed after clean stop" "$PIDFILE11"
wait "$GHEXE_PID" 2>/dev/null || true

# --- Case 12: unrelated process IS treated as stale (PID-reuse defense holds) --
SD12="$TEST_TMPDIR/own-unrelated"
mkdir -p "$SD12"
PIDFILE12="$TEST_TMPDIR/own-unrelated.pid"
sleep 30 &
UNREL_PID=$!
echo "$UNREL_PID" >"$PIDFILE12"
OUT=$(STUB_PS_ARGS='node /some/unrelated/process.js' run_stop_owncheck "$PIDFILE12" "$SD12")
assert_contains "case 12: unrelated args -> stale file removed (not signaled)" "$OUT" "stale file, removing"
assert_file_absent "case 12: stale PID file removed" "$PIDFILE12"
kill -TERM "$UNREL_PID" 2>/dev/null || true
wait "$UNREL_PID" 2>/dev/null || true

# --- Case 10: dead-PID pre-check is winpid-aware (codex r3327743095) ---
# stop_component must use pid::is_alive, not bare `kill -0`: on Windows a native
# gh.exe/Node PID invisible to `kill -0` would be mis-read as dead and its
# PID/lock/ready files removed while the process keeps running.
SUT_BODY=$(cat "$SCRIPT")
if [[ "$SUT_BODY" == *'pid::is_alive'* ]]; then
  pass "case 10: stop uses pid::is_alive (winpid-aware dead-PID check)"
else
  fail "case 10: stop uses pid::is_alive" "present" "missing"
fi

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
