#!/usr/bin/env bash
# tools/github-events/lib/broker-prune.sh — orphan-broker state-file pruner.
#
# Single source of truth for the "sweep dead sibling broker state files" logic
# shared by the daemon supervisor (start-github-watcher.sh startup
# self-reconciliation) and the stop script (stop-github-watcher.sh
# --prune-orphans). Both must agree on WHICH files count as orphans, so the
# rule lives once here rather than duplicated across the two callers.
#
# Crash-only-software / startup-reconciliation pattern: a broker that dies
# uncleanly (Windows TerminateProcess on SIGINT, OOM kill, power loss) leaves
# its broker-<slug>.pid + broker-<slug>.ports.json behind in STATE_DIR. The
# next supervisor boot reconciles by removing only files whose recorded PID is
# DEAD (or whose .pid body is empty / non-numeric). A LIVE broker's files are
# NEVER removed.
#
# WHY no live-PID identity check (reconcile ≠ stop): an earlier version also
# pruned a LIVE PID whose `ps` args did not match the broker entry, treating it
# as PID reuse. That is wrong for reconcile because the action here is file
# DELETION, not signalling. The threat models differ:
#   - stop-github-watcher.sh signals a PID → must defend against PID reuse so it
#     never SIGKILLs an innocent process that inherited a dead broker's PID.
#   - reconcile DELETES discovery files → deleting a live broker's port file
#     deadlocks channel mode (the live broker holds the lock, but nothing points
#     to it, so every new broker exits "another broker already running" and the
#     subscriber can never rediscover it). Empirically hit 2026-05-29.
# Cost asymmetry: deleting a live broker's state = unrecoverable deadlock;
# keeping a stale reused-PID file = bounded self-heal (subscriber hits a dead
# port once, next broker write / phase-2 prune cleans it). So reconcile KEEPS
# every live PID and prunes only provably-dead ones.
#
# Liveness is probed via pid::is_alive (tools/shared/process-management/pid-alive.sh)
# rather than bare `kill -0`: on Git Bash a native-Windows broker PID is invisible
# to MSYS `kill -0`, which would mis-classify a live broker as dead and trigger
# exactly the deletion-deadlock above.
#
# This is a LIBRARY — not executable, no side effects on source (no mkdir, no
# exit, no env reads at source time). The caller passes STATE_DIR explicitly.
# Sourcing pattern (per bash/conventions.md "Cross-tool shared libraries"):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/broker-prune.sh"
#   ghe::prune_dead_broker_files "$STATE_DIR"

# Include guard — sourcing twice is a no-op.
[[ -n "${_GHE_BROKER_PRUNE_SH:-}" ]] && return 0
_GHE_BROKER_PRUNE_SH=1

# Winpid-aware liveness primitive (pid::is_alive).
# shellcheck source=../../shared/process-management/pid-alive.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../shared/process-management/pid-alive.sh"

# ghe::prune_dead_broker_files <state_dir>
#
# Sweeps sibling broker state files in <state_dir>:
#   broker-<slug>.pid          — holds the broker PID (one line, "<pid>\n")
#   broker-<slug>.ports.json   — companion port-discovery file (no PID inside)
#
# For each broker-<slug>.pid file, the PID is read and classified:
#   - PID file empty / unreadable  → orphan: remove .pid + companion .ports.json
#   - PID non-numeric (corrupt)    → orphan: remove .pid + companion .ports.json
#   - PID not alive (pid::is_alive fails) → orphan: remove .pid + companion
#   - PID alive → LIVE broker: NEVER removed, companion .ports.json preserved
#
# A broker-<slug>.ports.json with NO matching broker-<slug>.pid is itself an
# orphan (the broker writes .pid before .ports.json and removes .pid before
# .ports.json on clean shutdown, so a lone .ports.json means an interrupted
# run). Such lone port files are removed.
#
# Args:
#   <state_dir>   directory holding broker-*.{pid,ports.json}. If absent,
#                 function returns 0 (nothing to prune).
#
# Stdout: one "pruned <file> (<reason>)" line per removed file (caller may
#         suppress or forward). Stderr: unused. Exit: always 0.
ghe::prune_dead_broker_files() {
  local state_dir="$1"

  [[ -d "$state_dir" ]] || return 0

  local pidf slug pid ports_file reason
  shopt -s nullglob
  # Phase 1: classify each .pid file; remove dead/empty/corrupt + companion.
  for pidf in "$state_dir"/broker-*.pid; do
    [[ -f "$pidf" ]] || continue
    slug="${pidf##*/broker-}"
    slug="${slug%.pid}"
    ports_file="$state_dir/broker-${slug}.ports.json"

    pid="$(tr -d '\r\n[:space:]' <"$pidf" 2>/dev/null || true)"

    reason=""
    if [[ -z "$pid" ]]; then
      reason="empty PID file"
    elif [[ ! "$pid" =~ ^[0-9]+$ ]]; then
      # Defensive: a non-numeric PID-file body must never reach kill/ps. Treat
      # it as a corrupt orphan rather than passing e.g. "-1" to kill (POSIX
      # reads a negative arg as a process-group signal).
      reason="non-numeric PID ($pid)"
    elif ! pid::is_alive "$pid"; then
      # Winpid-aware: on Git Bash, pid::is_alive falls back to tasklist so a
      # live native-Windows broker is NOT mis-classified as dead (which would
      # delete the live broker's discovery files and deadlock channel mode).
      reason="dead PID $pid"
    fi
    # A live PID (pid::is_alive succeeded) is ALWAYS kept — reconcile never
    # deletes a live broker's discovery files (see header: file-deletion ≠
    # signalling threat model).

    if [[ -n "$reason" ]]; then
      rm -f "$pidf"
      printf 'pruned %s (%s)\n' "$pidf" "$reason"
      if [[ -f "$ports_file" ]]; then
        rm -f "$ports_file"
        printf 'pruned %s (companion of orphaned %s)\n' "$ports_file" "$pidf"
      fi
    fi
  done

  # Phase 2: lone .ports.json with no matching .pid is an orphan.
  for ports_file in "$state_dir"/broker-*.ports.json; do
    [[ -f "$ports_file" ]] || continue
    slug="${ports_file##*/broker-}"
    slug="${slug%.ports.json}"
    pidf="$state_dir/broker-${slug}.pid"
    if [[ ! -f "$pidf" ]]; then
      rm -f "$ports_file"
      printf 'pruned %s (no matching PID file)\n' "$ports_file"
    fi
  done
  shopt -u nullglob

  return 0
}
