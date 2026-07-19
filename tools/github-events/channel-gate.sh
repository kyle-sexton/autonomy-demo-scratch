#!/usr/bin/env bash
# tools/github-events/channel-gate.sh — channel-mode activation gate (gates 1-4).
#
# Determines whether github-events channel mode is live for the current repo:
# the cli/gh-webhook extension is installed, the broker is running and healthy,
# and the `gh webhook forward` watcher is alive. Reads state-file paths from the
# shared SSOT lib (state-paths.sh) so it can NEVER drift from the daemon
# supervisor — the drift the 2026-05-28 audit found (documented gate probed
# ${TMPDIR}/... while the live daemon wrote ${LOCALAPPDATA}/github-events/...).
#
# This is a PURE PREDICATE — it checks + reports, it does NOT auto-remediate.
# The /pull-request skill decides whether to start the watcher on failure
# (keeps the gate testable; remediation is policy, detection is mechanism).
#
# Gate 5 (MCP subscriber freshness — "is the MCP subscriber connected to THIS
# broker, not a stale one") cannot run from bash: it needs the MCP
# `mcp__github-events__status` tool result, which only the agent can call.
# This script emits the live broker/receiver ports on stdout so the agent can
# cross-check gate 5 against them.
#
# Usage:
#   channel-gate.sh            # check gates 1-4; exit 0 = ready, 1 = off
#   channel-gate.sh --help
#   channel-gate.sh --quiet    # suppress per-gate stderr, machine-readable stdout only
#
# Stdout (machine-readable, always emitted):
#   CHANNEL_READY receiver=<port> broker=<port>     (all gates pass)
#   CHANNEL_OFF gate=<extension|port-file|broker-health|watcher-pid>  (first failure)
#
# Exit codes:
#   0  gates 1-4 pass (channel ready; agent still runs gate 5)
#   1  a gate failed (CHANNEL_OFF line names which)
#   3  invalid argument
#   4  prerequisite missing (jq or curl)

# -e omitted: predicate script — each gate failure calls off() which exits explicitly.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/state-paths.sh"
# Winpid-aware liveness (gate 4): gh.exe is a native Windows process whose PID
# bare `kill -0` cannot see from Git Bash — pid::is_alive falls back to tasklist.
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-alive.sh"

QUIET=0
case "${1:-}" in
  -h | --help)
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --quiet) QUIET=1 ;;
  "") ;;
  *)
    printf 'channel-gate: unknown argument %q (use --help)\n' "$1" >&2
    exit 3
    ;;
esac

note() { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
if ! have jq; then
  printf 'channel-gate: jq required (see /onboard Phase 0)\n' >&2
  exit 4
fi
if ! have curl; then
  printf 'channel-gate: curl required (see /onboard Phase 0)\n' >&2
  exit 4
fi

off() {
  printf 'CHANNEL_OFF gate=%s\n' "$1"
  exit 1
}

ghe::resolve_state_paths

# Gate 1 — cli/gh-webhook extension installed (NOT auto-remediable; needs user auth).
if ! gh extension list 2>/dev/null | grep -qE '(^|[[:space:]])cli/gh-webhook([[:space:]]|$)'; then
  note 'gate 1 (extension): cli/gh-webhook NOT installed — gh extension install cli/gh-webhook'
  off extension
fi
note 'gate 1 (extension): cli/gh-webhook installed'

# Gate 2 — broker port file exists + parses to receiver+broker ports.
if [[ ! -f "$GHE_PORT_FILE" ]]; then
  note "gate 2 (port-file): missing $GHE_PORT_FILE"
  off port-file
fi
RECEIVER_PORT="$(jq -r '.receiver // empty' "$GHE_PORT_FILE" 2>/dev/null | tr -d '\r')"
BROKER_PORT="$(jq -r '.broker // empty' "$GHE_PORT_FILE" 2>/dev/null | tr -d '\r')"
if [[ -z "$RECEIVER_PORT" || -z "$BROKER_PORT" ]]; then
  note "gate 2 (port-file): unparseable $GHE_PORT_FILE"
  off port-file
fi
note "gate 2 (port-file): receiver=$RECEIVER_PORT broker=$BROKER_PORT"

# Gate 3 — broker receiver /health responds 200.
if ! curl -fsS --max-time 2 "http://127.0.0.1:${RECEIVER_PORT}/health" >/dev/null 2>&1; then
  note "gate 3 (broker-health): no 200 at http://127.0.0.1:${RECEIVER_PORT}/health (stale port file?)"
  off broker-health
fi
note "gate 3 (broker-health): 200 at receiver $RECEIVER_PORT"

# Gate 4 — gh webhook forward watcher PID alive, identity matches, AND forwards
# to the CURRENT receiver port.
if [[ ! -f "$GHE_PID_FILE" ]]; then
  note "gate 4 (watcher-pid): missing $GHE_PID_FILE"
  off watcher-pid
fi
WATCHER_PID="$(tr -d '\r\n[:space:]' <"$GHE_PID_FILE")"
if [[ -z "$WATCHER_PID" ]]; then
  note "gate 4 (watcher-pid): empty PID file"
  off watcher-pid
elif [[ ! "$WATCHER_PID" =~ ^[0-9]+$ ]]; then
  # Defensive: a non-numeric PID-file body must never reach kill/ps. Bare
  # `kill -0 -1` is "all processes" on POSIX and would pass a corrupt "-1".
  note "gate 4 (watcher-pid): non-numeric PID '${WATCHER_PID}' in $GHE_PID_FILE"
  off watcher-pid
elif ! pid::is_alive "$WATCHER_PID"; then
  note "gate 4 (watcher-pid): PID $WATCHER_PID not alive"
  off watcher-pid
fi
# Identity + freshness defense — pid::is_alive only proves the PID exists. Verify
# (a) the FULL command line is our `gh webhook forward` and not an unrelated
# process the kernel reassigned the PID to, and (b) it forwards to the CURRENT
# receiver port: a watcher left from a prior broker (respawned on a new dynamic
# port) keeps forwarding to the stale `--url` port, so GitHub events never reach
# the live broker and channel mode silently drops PR events. Graceful: if `ps`
# cannot report args (Cygwin/MSYS2 `ps` lacks `-o`), fall back to the liveness
# result already established. The `:<port>/` match is colon-and-slash delimited
# so e.g. receiver 8788 does not spuriously match a `--url=...:18788/...`.
# Windows: `ps -o args=` reports the native executable form `.../gh.exe webhook
# forward`, which lacks the literal `gh webhook forward` substring — accept the
# `gh.exe` form too so a healthy native-Windows watcher is not mis-flagged as PID
# reuse (codex r3327091560).
if have ps; then
  WATCHER_ARGS="$(ps -p "$WATCHER_PID" -o args= 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$WATCHER_ARGS" ]]; then
    if [[ "$WATCHER_ARGS" != *"gh webhook forward"* && "$WATCHER_ARGS" != *"gh.exe webhook forward"* ]]; then
      note "gate 4 (watcher-pid): PID $WATCHER_PID is alive but not 'gh webhook forward' (args: $WATCHER_ARGS) — PID reuse"
      off watcher-pid
    fi
    if [[ "$WATCHER_ARGS" != *":${RECEIVER_PORT}/"* ]]; then
      note "gate 4 (watcher-pid): PID $WATCHER_PID forwards to a stale port — current receiver=$RECEIVER_PORT (args: $WATCHER_ARGS)"
      off watcher-pid
    fi
  fi
fi
note "gate 4 (watcher-pid): PID $WATCHER_PID alive, forwarding to receiver $RECEIVER_PORT"

printf 'CHANNEL_READY receiver=%s broker=%s\n' "$RECEIVER_PORT" "$BROKER_PORT"
exit 0
