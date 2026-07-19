#!/usr/bin/env bash
# Shared SIGTERM/SIGINT → wait → SIGKILL escalation for tools/ stop scripts.
#
# Consumers derive on demand via the repo dep-graph edge scan
# (tools/AGENTS.md "Vertical slices" — dep-graph row).
#
# Library — NOT executable. Pure-function: no env reads, no stdin parsing,
# no exit calls. Callers handle PID-liveness pre-check, PID-reuse defense
# (e.g. `ps -p <pid> -o args=` validation), message printing, post-exit
# cleanup (PID file + lock dir removal).

# pid::graceful_stop <pid> <first_signal> <attempts> <sleep_seconds>
#
# Sends <first_signal> (e.g. TERM, INT) to <pid>, polls for exit up to
# <attempts> times with <sleep_seconds> between polls. Escalates to SIGKILL
# + 3s confirm if still alive after the polling window.
#
# Args:
#   <pid>              POSIX process id (verified live by caller via kill -0)
#   <first_signal>     Signal name passed to `kill -<sig>` (TERM, INT, HUP)
#   <attempts>         Integer count of liveness polls before escalation
#   <sleep_seconds>    Decimal seconds between polls (e.g. 1, 0.1)
#
# Returns:
#   0 — exited cleanly after first signal
#   1 — required SIGKILL escalation; process now dead
#   2 — escalation FAILED; process still alive after SIGKILL + 3s confirm window
#
# Caller branches on the return code to surface the right message and
# decide cleanup vs error-exit. Errors from `kill` are suppressed inside
# the helper — caller's liveness pre-check is the contract.

# Winpid-aware liveness for the post-signal exit polls: on Git Bash/Windows a
# native gh.exe/Node PID is invisible to bare `kill -0`, which would make the
# poll declare a still-live process "exited" and return 0 (codex r3327743095).
# pid::is_alive falls back to `tasklist`, so the escalation/return code reflects
# the real state.
# shellcheck source=./pid-alive.sh
source "$(dirname "${BASH_SOURCE[0]}")/pid-alive.sh"

pid::graceful_stop() {
  local pid="$1" first_signal="$2" attempts="$3" sleep_seconds="$4"

  kill "-${first_signal}" "$pid" 2>/dev/null || true

  local i=0
  while ((i < attempts)); do
    if ! pid::is_alive "$pid"; then
      return 0
    fi
    sleep "$sleep_seconds"
    i=$((i + 1))
  done

  kill -KILL "$pid" 2>/dev/null || true

  i=0
  while ((i < 30)); do
    if ! pid::is_alive "$pid"; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done

  return 2
}
