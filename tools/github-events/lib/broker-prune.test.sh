#!/usr/bin/env bash
# Regression tests for tools/github-events/lib/broker-prune.sh.
#
# Black-box-ish: source the lib (it is a pure library with an include guard and
# no side effects on source), then drive ghe::prune_dead_broker_files against a
# fresh fixture STATE_DIR per case. Every case uses a $(mktemp -d) state dir —
# NEVER the real LOCALAPPDATA/github-events.
#
# Run: bash tools/github-events/lib/broker-prune.test.sh
# Or:  bash tools/run-shell-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/broker-prune.sh"
TEST_TMPDIR="$(mktemp -d)"

cleanup() {
  # CRITICAL: live cases seed real backgrounded processes. Reap them.
  local p
  for p in "${LIVE_PIDS[@]}"; do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_TMPDIR"
}
LIVE_PIDS=()
trap cleanup EXIT

# shellcheck source=../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# shellcheck source=./broker-prune.sh
source "$LIB"

# mk_state <name> — fresh per-case state dir under TEST_TMPDIR.
mk_state() {
  local d="$TEST_TMPDIR/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- Case A: dead-PID broker file is pruned (+ companion ports file) ----------
SD_A=$(mk_state dead-pid)
printf '999999\n' >"$SD_A/broker-int-aaa.pid"
printf '{"receiver":58620,"broker":58621}\n' >"$SD_A/broker-int-aaa.ports.json"
ghe::prune_dead_broker_files "$SD_A" >/dev/null
assert_file_absent "A: dead-PID .pid pruned" "$SD_A/broker-int-aaa.pid"
assert_file_absent "A: dead-PID companion .ports.json pruned" "$SD_A/broker-int-aaa.ports.json"

# --- Case B: LIVE broker file (broker-like args) is NOT pruned ----------------
SD_B=$(mk_state live)
bash -c 'exec -a "node /repo/mcp-servers/github-events/node/build/broker/index.js" sleep 30' &
LIVE_PID_B=$!
LIVE_PIDS+=("$LIVE_PID_B")
printf '%s\n' "$LIVE_PID_B" >"$SD_B/broker-int-bbb.pid"
printf '{"receiver":58622,"broker":58623}\n' >"$SD_B/broker-int-bbb.ports.json"
ghe::prune_dead_broker_files "$SD_B" >/dev/null
assert_file_exists "B: live broker .pid preserved" "$SD_B/broker-int-bbb.pid"
assert_file_exists "B: live broker companion .ports.json preserved" "$SD_B/broker-int-bbb.ports.json"

# --- Case C: LIVE PID with NON-broker args is STILL kept (FIX-A guarantee) ----
# A live PID whose args do NOT contain the broker entry must be KEPT — reconcile
# deletes files, and deleting a live broker's discovery file deadlocks channel
# mode, so reconcile never prunes a live PID regardless of its args. (An earlier
# version pruned this as "PID reuse"; that identity check was removed because the
# file-deletion threat model differs from stop's signalling — see broker-prune.sh
# header.) Uses this runner's own PID ($$): guaranteed alive, args are "bash
# <testfile>" — no broker entry. This is the regression guard for the behavior
# change; it must hold on every platform (no ps-capability branching).
SD_C=$(mk_state nonbroker-args)
printf '%s\n' "$$" >"$SD_C/broker-int-ccc.pid"
printf '{"receiver":58624,"broker":58625}\n' >"$SD_C/broker-int-ccc.ports.json"
ghe::prune_dead_broker_files "$SD_C" >/dev/null
assert_file_exists "C: live non-broker-args PID kept (no identity prune)" "$SD_C/broker-int-ccc.pid"
assert_file_exists "C: live non-broker-args companion kept" "$SD_C/broker-int-ccc.ports.json"

# --- Case D: empty PID file is pruned -----------------------------------------
SD_D=$(mk_state empty-pid)
: >"$SD_D/broker-int-eee.pid"
printf '{"receiver":58628,"broker":58629}\n' >"$SD_D/broker-int-eee.ports.json"
ghe::prune_dead_broker_files "$SD_D" >/dev/null
assert_file_absent "D: empty .pid pruned" "$SD_D/broker-int-eee.pid"
assert_file_absent "D: empty .pid companion pruned" "$SD_D/broker-int-eee.ports.json"

# --- Case D2: non-numeric (corrupt) PID file is pruned ------------------------
SD_D2=$(mk_state corrupt-pid)
printf 'not-a-pid\n' >"$SD_D2/broker-int-hhh.pid"
printf '{"receiver":58630,"broker":58631}\n' >"$SD_D2/broker-int-hhh.ports.json"
ghe::prune_dead_broker_files "$SD_D2" >/dev/null
assert_file_absent "D2: non-numeric .pid pruned" "$SD_D2/broker-int-hhh.pid"
assert_file_absent "D2: non-numeric companion pruned" "$SD_D2/broker-int-hhh.ports.json"

# --- Case E: lone .ports.json with no matching .pid is pruned -----------------
SD_E=$(mk_state lone-ports)
printf '{"receiver":58632,"broker":58633}\n' >"$SD_E/broker-int-fff.ports.json"
ghe::prune_dead_broker_files "$SD_E" >/dev/null
assert_file_absent "E: lone .ports.json pruned" "$SD_E/broker-int-fff.ports.json"

# --- Case F: live broker's .ports.json (with live .pid) is preserved ----------
# Guard against the Phase 2 loop deleting a live broker's ports file.
SD_F=$(mk_state live-with-ports)
sleep 30 &
LIVE_PID_F=$!
LIVE_PIDS+=("$LIVE_PID_F")
printf '%s\n' "$LIVE_PID_F" >"$SD_F/broker-int-ggg.pid"
printf '{"receiver":58634,"broker":58635}\n' >"$SD_F/broker-int-ggg.ports.json"
ghe::prune_dead_broker_files "$SD_F" >/dev/null
assert_file_exists "F: live broker .pid preserved (phase2 guard)" "$SD_F/broker-int-ggg.pid"
assert_file_exists "F: live broker .ports.json preserved (phase2 guard)" "$SD_F/broker-int-ggg.ports.json"

# --- Case G: missing state dir is a no-op (exit 0, no error) ------------------
ghe::prune_dead_broker_files "$TEST_TMPDIR/does-not-exist" >/dev/null
assert_exit "G: missing state dir → exit 0" 0 "$?"

# --- Case H: mixed dir — dead pruned, live kept in one sweep ------------------
SD_H=$(mk_state mixed)
printf '999999\n' >"$SD_H/broker-int-dead.pid"
printf '{"receiver":1,"broker":2}\n' >"$SD_H/broker-int-dead.ports.json"
sleep 30 &
LIVE_PID_H=$!
LIVE_PIDS+=("$LIVE_PID_H")
printf '%s\n' "$LIVE_PID_H" >"$SD_H/broker-int-alive.pid"
printf '{"receiver":3,"broker":4}\n' >"$SD_H/broker-int-alive.ports.json"
ghe::prune_dead_broker_files "$SD_H" >/dev/null
assert_file_absent "H: mixed — dead .pid pruned" "$SD_H/broker-int-dead.pid"
assert_file_absent "H: mixed — dead companion pruned" "$SD_H/broker-int-dead.ports.json"
assert_file_exists "H: mixed — live .pid kept" "$SD_H/broker-int-alive.pid"
assert_file_exists "H: mixed — live companion kept" "$SD_H/broker-int-alive.ports.json"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
