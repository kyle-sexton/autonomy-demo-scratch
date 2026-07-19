#!/usr/bin/env bash
# tools/github-events/stop-github-watcher.sh — Full-stack shutdown for the github-events pipeline.
#
# Stops ALL components in order:
#   1. gh webhook forward (watcher PID)
#   2. github-events broker (broker PID)
#   3. Cleans stale temp files (PID files, port file, lock dir, readiness sentinel)
#
# Idempotent — safe to run when nothing is running (cleans stale files only).
#
# Usage:
#   tools/github-events/stop-github-watcher.sh
#   tools/github-events/stop-github-watcher.sh --prune-orphans   # prune dead sibling
#                                                              # broker state files only;
#                                                              # kills nothing live, exit 0
#
# Env overrides:
#   GITHUB_EVENTS_PID_FILE   default ${STATE_DIR}/watcher-<repo-slug>.pid
#   GITHUB_EVENTS_REPO_SLUG  override repo slug (default: repo identity from git origin)
#   GITHUB_EVENTS_SKIP_OWNERSHIP_CHECK  1 = skip process-name verification (test mode; default 0)
#   STOP_TIMEOUT          default 5 (seconds before SIGKILL per component)
#
# Exit codes:
#   0  all components stopped (or were not running) + stale files cleaned
#      OR --prune-orphans completed
#   2  a process could not be terminated even via SIGKILL
#   3  invalid argument

set -uo pipefail

# shellcheck source=../shared/process-management/pid-file-read.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-file-read.sh"
# shellcheck source=../shared/process-management/pid-graceful-stop.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-graceful-stop.sh"
# shellcheck source=../shared/process-management/pid-alive.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-alive.sh"
# shellcheck source=lib/broker-prune.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/broker-prune.sh"
# shellcheck source=state-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/state-paths.sh"

PRUNE_ORPHANS=0
case "${1:-}" in
  --prune-orphans) PRUNE_ORPHANS=1 ;;
  -h | --help)
    sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *)
    printf 'stop-github-watcher: unknown argument %q (use --help)\n' "$1" >&2
    exit 3
    ;;
esac

STOP_TIMEOUT="${STOP_TIMEOUT:-5}"

# --- Watcher (gh webhook forward) -------------------------------------------

# Resolve state paths via the shared SSOT lib (mirrors start-github-watcher.sh +
# channel-gate.sh; env.ts stateDir() agrees). One source for STATE_DIR / PID_FILE
# derivation so the --prune-orphans path can never drift from the daemon's.
ghe::resolve_state_paths
STATE_DIR="$GHE_STATE_DIR"
PID_FILE="$GHE_PID_FILE"
READY_FILE="$GHE_READY_FILE"
LOCK_DIR="$GHE_LOCK_DIR"

# --- --prune-orphans: dead sibling-broker prune only, then exit --------------
#
# Runs ONLY the dead/empty/corrupt sibling-broker prune from the shared lib
# (keeps every live PID — kills nothing). Mirror of the startup
# self-reconciliation in start-github-watcher.sh, exposed as an explicit
# one-shot for operators.
if [[ $PRUNE_ORPHANS -eq 1 ]]; then
  ghe::prune_dead_broker_files "$STATE_DIR" | sed 's/^/  /' || true
  printf 'Orphan-broker prune complete.\n'
  exit 0
fi

stop_component() {
  local label="$1" pid_file="$2" expected_pattern="${3:-}"
  if [[ ! -f "$pid_file" ]]; then
    printf '%s: no PID file — not running.\n' "$label"
    return 0
  fi

  local pid
  pid=$(pid_file::read "$pid_file" 2>/dev/null || true)

  if [[ -z "$pid" ]]; then
    printf '%s: PID file empty — removing.\n' "$label"
    rm -f "$pid_file"
    return 0
  fi

  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    printf '%s: PID file content %q not numeric — removing stale file.\n' "$label" "$pid"
    rm -f "$pid_file"
    return 0
  fi

  # Winpid-aware: a native gh.exe/Node PID is invisible to bare `kill -0`, which
  # would mis-read a LIVE process as "already dead" and remove its PID/lock/ready
  # files while it keeps running (codex r3327743095). pid::is_alive falls back to
  # `tasklist` on Windows.
  if ! pid::is_alive "$pid"; then
    printf '%s: PID %s already dead — cleaning stale file.\n' "$label" "$pid"
    rm -f "$pid_file"
    return 0
  fi

  if [[ -n "$expected_pattern" ]]; then
    local proc_args proc_args_norm
    proc_args=$(ps -p "$pid" -o args= 2>/dev/null | tr -d '\r') || true
    # Normalize Windows process-arg forms so the identity match works for a
    # native gh.exe watcher / node.exe broker (codex r3327793626): backslash
    # path separators → forward, and strip a `.exe` command suffix — so
    # `...\gh.exe webhook forward` → `.../gh webhook forward` and
    # `build\broker\index.js` → `build/broker/index.js`. Mirrors the dual-form
    # match in stop-webhook-broker.sh + channel-gate.sh gate 4.
    proc_args_norm="${proc_args//\\//}"
    proc_args_norm="${proc_args_norm//.exe/}"
    if [[ -n "$proc_args" && "$proc_args_norm" != *"$expected_pattern"* ]]; then
      printf '%s: PID %s is alive but not %s (args: %s) — stale file, removing.\n' \
        "$label" "$pid" "$expected_pattern" "$proc_args"
      rm -f "$pid_file"
      return 0
    fi
  fi

  printf '%s: sending SIGTERM to PID %s ...\n' "$label" "$pid"
  pid::graceful_stop "$pid" TERM "$STOP_TIMEOUT" 1
  local rc=$?

  case $rc in
    0)
      rm -f "$pid_file"
      printf '%s: stopped cleanly.\n' "$label"
      ;;
    1)
      rm -f "$pid_file"
      printf '%s: killed via SIGKILL after %ds.\n' "$label" "$STOP_TIMEOUT" >&2
      ;;
    *)
      printf 'ERROR: %s PID %s still alive after SIGKILL — preserving PID file.\n' "$label" "$pid" >&2
      return 2
      ;;
  esac
  return 0
}

# Stop watcher first (depends on broker; stopping broker first would leave gh webhook forward orphaned).
# GITHUB_EVENTS_SKIP_OWNERSHIP_CHECK=1 skips process-name verification (test mode).
WATCHER_PATTERN=""
[[ "${GITHUB_EVENTS_SKIP_OWNERSHIP_CHECK:-0}" != "1" ]] && WATCHER_PATTERN="gh webhook forward"
stop_component "watcher" "$PID_FILE" "$WATCHER_PATTERN" || exit 2

# --- Broker ------------------------------------------------------------------

BROKER_PID_FILE="${STATE_DIR}/broker-${GHE_REPO_SLUG}.pid"
PORT_FILE="$GHE_PORT_FILE"

BROKER_PATTERN=""
[[ "${GITHUB_EVENTS_SKIP_OWNERSHIP_CHECK:-0}" != "1" ]] && BROKER_PATTERN="build/broker/index.js"
stop_component "broker" "$BROKER_PID_FILE" "$BROKER_PATTERN" || exit 2

# --- Stale file cleanup ------------------------------------------------------

cleanup_count=0
for f in "$READY_FILE" "$PORT_FILE"; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    cleanup_count=$((cleanup_count + 1))
  fi
done
if [[ -d "$LOCK_DIR" ]]; then
  rm -rf "$LOCK_DIR"
  cleanup_count=$((cleanup_count + 1))
fi

if ((cleanup_count > 0)); then
  printf 'Cleaned %d stale temp file(s).\n' "$cleanup_count"
fi

printf 'All github-events components stopped.\n'
exit 0
