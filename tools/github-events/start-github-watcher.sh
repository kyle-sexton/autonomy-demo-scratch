#!/usr/bin/env bash
# tools/github-events/start-github-watcher.sh — Supervisor for `gh webhook forward` paired with
# the github-events MCP server.
#
# Boots `gh webhook forward` to push GitHub PR/CI events to the github-events
# MCP server's HTTP listener (default 127.0.0.1:8788). Two-step readiness:
# only writes the PID file after BOTH the MCP server's /health responds 200
# AND `gh webhook forward` reports its subscription is established. On exit
# (signal, gh-forward death, or user Ctrl-C) removes the PID file and the
# readiness sentinel so the /pull-request skill's channel-mode detection
# falls through to Monitor watch.
#
# Daemon by default:
# The script forks a detached child via `nohup ... </dev/null >>LOG 2>&1 &`,
# waits for the child to write a readiness sentinel, reports + exits. The
# child survives the parent terminal closing (channel-mode activation gate
# in monitor.md §3.0.05 now passes reliably across reboot/Ctrl-C/terminal
# close). The `--foreground` flag runs blocking in the current process for
# debug or systemd/launchd integration where an external supervisor owns
# lifecycle.
#
# Hook reconcile (before every `gh webhook forward` launch — initial + relaunch):
# `gh webhook forward` creates a repo webhook pointing at the GitHub CLI relay
# (webhook-forwarder.github.com) and never deletes it, so a leftover hook from a
# prior run makes the next launch fail "422 Hook already exists". The reconcile
# (ghe::ensure_no_stale_cli_hook in broker-supervisor.sh) deletes any pre-existing
# relay hook first; safe because the per-repo watcher lock makes this the sole
# local forwarder. Skipped under GITHUB_EVENTS_SKIP_GH=1; a `gh api` failure (e.g.
# missing admin:repo_hook scope) aborts with an actionable message rather than a
# cryptic downstream 422.
#
# Concurrent-invocation guard: an atomic lock directory (mkdir) gates the
# health/subscription/PID-write block. Cross-platform — flock is unavailable
# on stock macOS and Git Bash; mkdir is atomic on every POSIX-ish filesystem.
# If the lock is held AND its recorded PID is alive, exits 0 with an "already
# running" message rather than racing. In daemon mode the parent additionally
# pre-flights the PID file to short-circuit before forking.
#
# Placement rationale (.claude/rules/bash/conventions.md script-placement):
# Lives under tools/ rather than mcp-servers/github-events/node/scripts/ or
# .claude/skills/pull-request/scripts/ because it is a long-running supervisor
# the user invokes from a separate shell — outside the Claude Code process
# tree. tools/ is the conventional home for shared dev scripts of this
# lifecycle shape (build helpers, deployment, supervisors).
#
# Usage:
#   tools/github-events/start-github-watcher.sh                # daemonizes; returns when subscribed
#   tools/github-events/start-github-watcher.sh --foreground   # foreground; blocks until gh exits
#   tools/github-events/start-github-watcher.sh --dry-run      # print plan, exit 0
#
# Env overrides (test-friendly):
#   GITHUB_EVENTS_PORT          default 8788
#   GITHUB_EVENTS_REPO          repo identity (owner/repo) for the forwarder +
#                            hook reconcile; default resolved from `git remote
#                            get-url origin` via the shared state-paths lib (no
#                            hardcoded single-repo fallback)
#   GITHUB_EVENTS_TYPES        default * (all GitHub events)
#   GITHUB_EVENTS_PID_FILE      default ${TMPDIR:-/tmp}/github-events.pid — recommend
#                            ${XDG_RUNTIME_DIR}/github-events.pid on shared Linux
#                            to avoid /tmp symlink-attack vector (see
#                            .claude/skills/onboard/context/per-concern/webhook-channel.md)
#   GITHUB_EVENTS_LOCK_DIR      default ${GITHUB_EVENTS_PID_FILE}.lock — atomic guard
#                            for TOCTOU between PID-file check and write
#   GITHUB_EVENTS_DAEMON_LOG    default ${TMPDIR:-/tmp}/github-events-daemon.log —
#                            stable path for daemonized child's stdout/stderr
#                            (overwritten on every parent start)
#   GITHUB_EVENTS_READY_TIMEOUT default 60 (seconds parent waits for child to
#                            write the readiness sentinel before timing out)
#   GITHUB_EVENTS_HEALTH_RETRIES   default 30 (1s each)
#   GITHUB_EVENTS_SUBSCRIBE_RETRIES default 15 (1s each)
#   GITHUB_EVENTS_SKIP_GH       if 1, skip launching gh — used by tests to
#                            exercise readiness logic without real network.
#                            In test mode the script writes a PID file with
#                            its own PID, writes the readiness sentinel, and
#                            blocks on a `sleep` so SIGTERM cleanup can be
#                            asserted.
#   GITHUB_EVENTS_SKIP_HEALTH   if 1, skip the broker /health check entirely.
#                            Used together with GITHUB_EVENTS_SKIP_GH=1 to
#                            exercise daemon-mode end-to-end without
#                            spawning a stub HTTP listener. Never set
#                            outside tests.
#
# Exit codes:
#   0  normal shutdown OR --dry-run OR already-running OR daemon parent OK
#   1  MCP server /health unreachable after retries OR daemon child died early
#   2  gh webhook forward exited before subscription established
#      OR daemon parent readiness-poll timed out
#   3  invalid argument
#   4  prerequisite missing (gh CLI or curl)
#   5  lock could not be acquired (concurrent invocation race)

# Omit -e: capture exit codes from health/subscription waits explicitly.
set -uo pipefail

# shellcheck source=../shared/process-management/pid-file-read.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-file-read.sh"
# shellcheck source=../shared/process-management/pid-alive.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-alive.sh"
# shellcheck source=lib/broker-prune.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/broker-prune.sh"
# shellcheck source=./broker-supervisor.sh
source "$(dirname "${BASH_SOURCE[0]}")/broker-supervisor.sh"

# --- Argument parsing ---------------------------------------------------------

DRY_RUN=0
FOREGROUND=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --foreground) FOREGROUND=1 ;;
  -h | --help)
    # Print the header front-matter (description + daemon/lock/reconcile notes +
    # Usage examples), stopping before the exhaustive "Env overrides" reference.
    # Dynamic boundary (not a fixed line range) so header growth never silently
    # truncates the Usage block out of --help.
    sed -n '2,/^# Env overrides/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *)
    printf 'start-github-watcher: unknown argument %q (use --help)\n' "$1" >&2
    exit 3
    ;;
esac

# --- Config (env-overridable) -------------------------------------------------

# State-file paths resolved via the shared SSOT lib so this supervisor and the
# channel-mode gate (channel-gate.sh) can NEVER drift. Mirrors stateDir() +
# repoSlug() in env.ts (cross-language contract; same convention, not shared code).
# shellcheck source=state-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/state-paths.sh"
ghe::resolve_state_paths
STATE_DIR="$GHE_STATE_DIR"
REPO_SLUG="$GHE_REPO_SLUG"
PID_FILE="$GHE_PID_FILE"
READY_FILE="$GHE_READY_FILE"
LOCK_DIR="$GHE_LOCK_DIR"
PORT_FILE="$GHE_PORT_FILE"

if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  printf 'ERROR: cannot create state directory %s\n' "$STATE_DIR" >&2
  exit 1
fi

PORT="${GITHUB_EVENTS_PORT:-}"
# Repo identity (owner/repo) for `gh webhook forward --repo` + the hook reconcile.
# Resolved by the shared state-paths lib (ghe::resolve_state_paths above):
# GITHUB_EVENTS_REPO env if set, else parsed from `git remote get-url origin`.
# No hardcoded single-repo default — an empty identity (detached / no-origin
# checkout) is caught by an explicit guard at the Step 2 launch with a clear
# message, not silently coerced to one repo.
REPO="${GHE_REPO_IDENTITY}"
EVENTS="${GITHUB_EVENTS_TYPES:-*}"
DAEMON_LOG="${GITHUB_EVENTS_DAEMON_LOG:-${STATE_DIR}/watcher-daemon.log}"
READY_TIMEOUT="${GITHUB_EVENTS_READY_TIMEOUT:-60}"
HEALTH_RETRIES="${GITHUB_EVENTS_HEALTH_RETRIES:-30}"
SUBSCRIBE_RETRIES="${GITHUB_EVENTS_SUBSCRIBE_RETRIES:-15}"

# Port-dependent URLs are set after port discovery (see discover_ports below).
HEALTH_URL=""
WEBHOOK_URL=""

# Are we the detached child re-executed by the parent? Sentinel env wins
# unconditionally so a stale shell that re-runs the script does not
# accidentally enter child mode.
DAEMON_CHILD="${__GITHUB_EVENTS_DAEMON_CHILD:-0}"

# --- Plan banner --------------------------------------------------------------

# Discover actual ports from the port file written by the broker after bind.
# Sets PORT (receiver) and BROKER_PORT, plus derived HEALTH_URL / WEBHOOK_URL.
# Returns 0 on success, 1 when port file missing or unparseable.
discover_ports() {
  if [[ ! -f "$PORT_FILE" ]]; then
    return 1
  fi
  local receiver broker
  receiver=$(jq -r '.receiver // empty' "$PORT_FILE" 2>/dev/null | tr -d '\r') || return 1
  broker=$(jq -r '.broker // empty' "$PORT_FILE" 2>/dev/null | tr -d '\r') || return 1
  if [[ -z "$receiver" || -z "$broker" ]]; then
    return 1
  fi
  PORT="$receiver"
  BROKER_PORT="$broker"
  HEALTH_URL="http://127.0.0.1:${PORT}/health"
  WEBHOOK_URL="http://127.0.0.1:${PORT}/webhook"
  return 0
}

# If PORT was set explicitly via env, use it for static URLs (backward compat).
if [[ -n "$PORT" ]]; then
  HEALTH_URL="http://127.0.0.1:${PORT}/health"
  WEBHOOK_URL="http://127.0.0.1:${PORT}/webhook"
fi

print_plan() {
  printf 'github-events watcher plan\n'
  printf '  port:           %s\n' "${PORT:-dynamic (OS-assigned)}"
  printf '  repo:           %s\n' "$REPO"
  printf '  events:         %s\n' "$EVENTS"
  printf '  health url:     %s\n' "${HEALTH_URL:-(discovered after broker bind)}"
  printf '  webhook url:    %s\n' "${WEBHOOK_URL:-(discovered after broker bind)}"
  printf '  port file:      %s\n' "$PORT_FILE"
  printf '  pid file:       %s\n' "$PID_FILE"
  printf '  ready file:     %s\n' "$READY_FILE"
  printf '  lock dir:       %s\n' "$LOCK_DIR"
  printf '  daemon log:     %s\n' "$DAEMON_LOG"
  printf '  ready timeout:  %ss\n' "$READY_TIMEOUT"
  printf '  health retries: %s (1s each)\n' "$HEALTH_RETRIES"
  printf '  subscribe wait: %s (1s each)\n' "$SUBSCRIBE_RETRIES"
  if [[ $FOREGROUND -eq 1 ]]; then
    printf '  mode:           foreground (blocking)\n'
  else
    printf '  mode:           daemon (default)\n'
  fi
}

if [[ $DRY_RUN -eq 1 ]]; then
  print_plan
  printf 'Dry-run complete. Re-run without --dry-run to start the watcher.\n'
  exit 0
fi

# --- Helpers ------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve the current worktree's repo root. Uses `git rev-parse --show-toplevel`
# which returns the correct root for both main and linked worktrees.
resolve_repo_root() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  if [[ -z "$toplevel" ]]; then
    printf 'ERROR: not inside a git repository.\n' >&2
    return 1
  fi
  printf '%s' "$toplevel"
}

# Ensure the broker's Node.js project has build artifacts in the current
# worktree. Worktrees share source files via git but not gitignored artifacts
# (node_modules/, build/). Auto-installs and builds when missing.
ensure_broker_built() {
  local repo_root="$1"
  local broker_dir="${repo_root}/mcp-servers/github-events/node"
  local broker_entry="${broker_dir}/build/broker/index.js"

  if [[ -f "$broker_entry" ]]; then
    return 0
  fi

  if [[ ! -d "$broker_dir" ]]; then
    printf 'ERROR: broker source not found at %s\n' "$broker_dir" >&2
    return 1
  fi

  printf 'Broker not built in this worktree — installing and building ...\n'
  if ! have node; then
    printf 'ERROR: node required to build broker.\n' >&2
    return 1
  fi
  if ! (cd "$broker_dir" && npm install --ignore-scripts 2>&1 && npm run build 2>&1); then
    printf 'ERROR: broker build failed. Run manually: cd %s && npm install && npm run build\n' "$broker_dir" >&2
    return 1
  fi

  if [[ ! -f "$broker_entry" ]]; then
    printf 'ERROR: broker build completed but %s not found.\n' "$broker_entry" >&2
    return 1
  fi
  printf 'Broker built successfully.\n'
}

# Spawn the broker process and wait for its port file.
spawn_broker() {
  local repo_root broker_entry
  repo_root="$(resolve_repo_root)" || return 1
  ensure_broker_built "$repo_root" || return 1
  broker_entry="${repo_root}/mcp-servers/github-events/node/build/broker/index.js"
  local broker_log="${STATE_DIR}/broker.log"
  printf 'Broker log: %s\n' "$broker_log"
  GITHUB_EVENTS_REPO_SLUG="$REPO_SLUG" nohup node "$broker_entry" </dev/null >>"$broker_log" 2>&1 &
  disown 2>/dev/null || true

  printf 'Waiting for broker port file at %s ...\n' "$PORT_FILE"
  local attempt=0 discovered=0
  while ((attempt < HEALTH_RETRIES)); do
    if discover_ports; then
      discovered=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  if [[ $discovered -ne 1 ]]; then
    return 1
  fi
  return 0
}

# Verify curl + gh (skipping gh in test mode). Called from both the daemon
# parent (pre-fork) and the child/foreground path. Exits 4 on missing tool.
check_prerequisites() {
  if ! have curl; then
    printf 'start-github-watcher: curl required (see /onboard Phase 0)\n' >&2
    exit 4
  fi
  if ! have jq; then
    printf 'start-github-watcher: jq required for port discovery (see /onboard Phase 0)\n' >&2
    exit 4
  fi
  if [[ "${GITHUB_EVENTS_SKIP_GH:-0}" != "1" ]] && ! have gh; then
    printf 'start-github-watcher: gh CLI required (see /onboard Phase -1)\n' >&2
    exit 4
  fi
}

# --- Daemon parent path -------------------------------------------------------
#
# Default mode forks a detached child via `nohup`, waits for the child to
# write the readiness sentinel, reports + exits. Survives terminal close.
#
# Pre-flight: short-circuit when a live daemon already exists (better UX than
# letting the child enter acquire_lock_or_die and detect it).

daemonize_parent() {
  if [[ -f "$PID_FILE" ]]; then
    local existing_pid
    existing_pid=$(pid_file::read "$PID_FILE" 2>/dev/null || true)
    if [[ -n "$existing_pid" ]] && pid::is_alive "$existing_pid"; then
      printf 'github-events watcher already running (PID %s). Stop it via tools/github-events/stop-github-watcher.sh.\n' "$existing_pid"
      exit 0
    fi
  fi

  check_prerequisites

  # Clear any stale readiness sentinel from a previous run BEFORE forking the
  # new child. We do NOT clear the PID file here — acquire_lock_or_die in the
  # child handles the orphan/stale matrix authoritatively.
  rm -f "$READY_FILE"

  # Truncate daemon log so each parent start sees a fresh post-mortem buffer.
  : >"$DAEMON_LOG"

  # Fork detached child. nohup + redirect + disown is the portable cross-
  # platform pattern (Git Bash MSYS2 / macOS / Linux) per research 2026-05-16.
  # setsid is not portable — Git for Windows installs may omit the binary.
  __GITHUB_EVENTS_DAEMON_CHILD=1 nohup "${BASH_SOURCE[0]}" </dev/null >>"$DAEMON_LOG" 2>&1 &
  local child_pid=$!
  disown 2>/dev/null || true

  # Wait for readiness sentinel OR child death OR timeout.
  local attempt=0
  while ((attempt < READY_TIMEOUT)); do
    if [[ -f "$READY_FILE" ]]; then
      local child_pid_actual
      child_pid_actual=$(pid_file::read "$PID_FILE" 2>/dev/null || echo "?")
      printf 'Watcher daemon started.\n'
      printf '  PID:      %s\n' "$child_pid_actual"
      printf '  PID file: %s\n' "$PID_FILE"
      printf '  Log:      %s\n' "$DAEMON_LOG"
      printf '  Stop:     bash tools/github-events/stop-github-watcher.sh\n'
      exit 0
    fi
    if ! pid::is_alive "$child_pid"; then
      printf 'ERROR: watcher daemon child died before readiness. Log tail:\n' >&2
      tail -n 20 "$DAEMON_LOG" 2>/dev/null | sed 's/^/  /' >&2 || true
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  printf 'ERROR: watcher daemon did not report readiness within %ds. Log tail:\n' "$READY_TIMEOUT" >&2
  tail -n 20 "$DAEMON_LOG" 2>/dev/null | sed 's/^/  /' >&2 || true
  kill "$child_pid" 2>/dev/null || true
  exit 2
}

if [[ "$DAEMON_CHILD" != "1" && "$FOREGROUND" -ne 1 ]]; then
  daemonize_parent
fi

# --- Child / foreground path: lock acquisition --------------------------------
#
# `mkdir` is atomic on every POSIX-ish filesystem (succeeds OR fails — never
# partially). Two concurrent invocations cannot both succeed. Used in place
# of `flock` because flock is unavailable on stock macOS and Git Bash.
#
# Lock-state matrix:
#   lock free  + no PID file       → acquire, continue (normal first-run)
#   lock free  + stale PID file    → cleanup + acquire (prior run died unclean)
#   lock held  + live PID          → "already running", exit 0
#   lock held  + dead PID / no PID → reclaim orphaned lock, acquire (one retry)
#
# Trap is installed IMMEDIATELY after first successful acquire so a later
# failure (prereq check, health timeout) cannot leak the lock dir.

acquire_lock_or_die() {
  local existing_pid=""
  if [[ -f "$PID_FILE" ]]; then
    existing_pid=$(pid_file::read "$PID_FILE")
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    if [[ -n "$existing_pid" ]]; then
      printf 'Removing stale PID file (PID %s, lock was unheld): %s\n' \
        "$existing_pid" "$PID_FILE" >&2
      rm -f "$PID_FILE" "$READY_FILE"
    fi
    return 0
  fi

  # Lock held — is there a live owner?
  if [[ -n "$existing_pid" ]] && pid::is_alive "$existing_pid"; then
    printf 'github-events watcher already running (PID %s). Stop it via tools/github-events/stop-github-watcher.sh.\n' "$existing_pid"
    exit 0
  fi

  # Orphaned lock: process died between mkdir and PID-write OR after start.
  printf 'Removing stale lock dir + PID file (PID %s no longer alive): %s\n' \
    "${existing_pid:-?}" "$LOCK_DIR" >&2
  rm -rf "$LOCK_DIR"
  rm -f "$PID_FILE" "$READY_FILE"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  printf 'ERROR: lock %s could not be acquired after stale-lock recovery.\n' "$LOCK_DIR" >&2
  exit 5
}

acquire_lock_or_die

# Install cleanup trap NOW — any exit from here forward must release the lock.
# GH_LOG / GH_PID / TAIL_PID are set later (mktemp + background launches);
# initialise them so the trap is safe under `set -u` on every early-exit path
# (the SKIP_GH test path never sets GH_PID / TAIL_PID).
GH_LOG=""
GH_PID=""
TAIL_PID=""
cleanup() {
  [[ -n "${GH_PID:-}" ]] && ghe::kill_and_reap "$GH_PID"
  [[ -n "${TAIL_PID:-}" ]] && ghe::kill_and_reap "$TAIL_PID"
  rm -f "${GH_LOG:-}" "$PID_FILE" "$READY_FILE"
  rm -rf "$LOCK_DIR"
}
trap cleanup EXIT INT TERM

# --- Startup self-reconciliation (crash-only-software) ------------------------
#
# Sweep SIBLING broker-<slug>.{pid,ports.json} files in STATE_DIR left behind by
# a broker that died uncleanly (Windows TerminateProcess on SIGINT, OOM, power
# loss). Remove only files whose recorded PID is DEAD (or empty / non-numeric).
# A LIVE broker's files are NEVER removed — reconcile deletes files, and deleting
# a live broker's discovery file deadlocks channel mode (see broker-prune.sh
# header: file-deletion ≠ signalling threat model). Liveness is winpid-aware via
# pid::is_alive so a native-Windows broker is not mis-pruned. Runs only after we
# own the watcher lock so it cannot race a peer supervisor mid-boot.
ghe::prune_dead_broker_files "$STATE_DIR" | sed 's/^/  reconciled: /' || true

# --- Prerequisite check -------------------------------------------------------

check_prerequisites

# --- Step 1: wait for MCP server liveness -------------------------------------

if [[ "${GITHUB_EVENTS_SKIP_HEALTH:-0}" == "1" ]]; then
  printf 'GITHUB_EVENTS_SKIP_HEALTH=1 — skipping broker /health check (test mode).\n'
else
  # Auto-start broker if not running. Broker binds dynamic ports and writes
  # port file; we discover actual ports from that file.
  if [[ -z "$HEALTH_URL" ]] && ! discover_ports; then
    if [[ "${GITHUB_EVENTS_SKIP_GH:-0}" == "1" ]]; then
      # Test mode (no real gh): do NOT auto-spawn a real broker — spawn_broker
      # runs ensure_broker_built (npm install/build) on a fresh clone, which would
      # make the no-gh shell tests unbounded / hang. The
      # stale-PID + lock reconciliation above has already run; exit so those cases
      # stay bounded.
      printf 'GITHUB_EVENTS_SKIP_GH=1 — broker not running, skipping auto-spawn (test mode).\n' >&2
      exit 1
    fi
    printf 'Broker not running — auto-spawning ...\n'
    if spawn_broker; then
      printf '  Port file found: receiver=%s broker=%s\n' "$PORT" "$BROKER_PORT"
    else
      printf 'ERROR: broker did not start within %ds.\n' "$HEALTH_RETRIES" >&2
      printf '  - Check broker build: cd mcp-servers/github-events/node && npm run build\n' >&2
      printf '  - Check Node.js: node --version\n' >&2
      exit 1
    fi
  fi

  # If ports already known (explicit env or discovered above), probe health.
  if [[ -n "$HEALTH_URL" ]]; then
    printf 'Waiting for github-events broker at %s ...\n' "$HEALTH_URL"
    attempt=0
    healthy=0
    while ((attempt < HEALTH_RETRIES)); do
      if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
        healthy=1
        printf '  OK (after %ds)\n' "$attempt"
        break
      fi
      attempt=$((attempt + 1))
      sleep 1
    done

    if [[ $healthy -ne 1 ]]; then
      if [[ "${GITHUB_EVENTS_SKIP_GH:-0}" == "1" ]]; then
        # Test mode: don't re-spawn a real broker (npm build) — see auto-spawn
        # guard above.
        printf 'GITHUB_EVENTS_SKIP_GH=1 — broker unhealthy, skipping re-spawn (test mode).\n' >&2
        exit 1
      fi
      printf 'Broker unreachable at %s — stale port file, removing and re-spawning ...\n' "$HEALTH_URL" >&2
      rm -f "$PORT_FILE"
      HEALTH_URL=""
      WEBHOOK_URL=""
      if spawn_broker; then
        printf '  Re-spawned broker: receiver=%s broker=%s\n' "$PORT" "$BROKER_PORT"
      else
        printf 'ERROR: broker re-spawn failed within %ds.\n' "$HEALTH_RETRIES" >&2
        exit 1
      fi
    fi
  fi
fi

# --- Step 2: launch gh webhook forward in background -------------------------

if [[ "${GITHUB_EVENTS_SKIP_GH:-0}" == "1" ]]; then
  printf 'GITHUB_EVENTS_SKIP_GH=1 — skipping gh webhook forward launch (test mode).\n'
  # Simulate ready daemon: write PID + readiness sentinel, then block on
  # sleep so the parent's poll loop sees readiness and so SIGTERM cleanup
  # can be exercised end-to-end by the regression suite. Trap cleanup still
  # fires on EXIT/INT/TERM.
  printf '%s' "$$" >"$PID_FILE"
  : >"$READY_FILE"
  printf 'PID file: %s (PID %d)\n' "$PID_FILE" "$$"
  printf 'TEST mode: ready signal written, sleeping until SIGTERM.\n'
  # Bound the sleep so a stuck test cannot leave an orphaned background
  # process indefinitely; 30s is well past any reasonable parent timeout.
  sleep 30 &
  SLEEP_PID=$!
  wait "$SLEEP_PID"
  exit 0
fi

# Guard an unresolved repo identity (detached / no-origin checkout). Without it,
# `gh webhook forward --repo=` and the hook reconcile both fail cryptically; a
# clear message + actionable fix beats a downstream 4xx (resolves the [FALLBACK]
# decision: a clear message, not a hardcoded single-repo default).
if [[ -z "$REPO" ]]; then
  printf 'ERROR: could not resolve repo identity (no GITHUB_EVENTS_REPO and no git origin remote).\n' >&2
  printf '  Set GITHUB_EVENTS_REPO=owner/repo, or run from a checkout with an origin remote.\n' >&2
  exit 4
fi

# Reconcile any stale relay webhook before launching the forwarder (see header
# "Hook reconcile" + ghe::ensure_no_stale_cli_hook). We hold the per-repo watcher
# lock here, so delete+recreate cannot race a peer. A failed reconcile (e.g.
# missing admin:repo_hook scope) aborts with the actionable message already
# emitted, rather than letting `gh webhook forward` fail on a cryptic 422.
if ! ghe::ensure_no_stale_cli_hook; then
  printf 'ERROR: could not reconcile webhooks before launch (see above) — aborting.\n' >&2
  exit 2
fi

GH_LOG=$(mktemp)

printf 'Starting gh webhook forward (repo=%s) ...\n' "$REPO"
gh webhook forward \
  --repo="$REPO" \
  --events="$EVENTS" \
  --url="$WEBHOOK_URL" \
  >"$GH_LOG" 2>&1 &
GH_PID=$!

# --- Step 3: wait for subscription confirmation ------------------------------
# Shared with the broker-supervisor's forwarder relaunch (ghe::restart_forwarder)
# so initial launch and port-change relaunch gate on the same signal.

if ! ghe::wait_for_subscription; then
  printf 'ERROR: gh webhook forward did not confirm subscription within %ds (or exited early). Output:\n' "$SUBSCRIBE_RETRIES" >&2
  sed 's/^/  /' "$GH_LOG" >&2
  kill "$GH_PID" 2>/dev/null || true
  exit 2
fi

# --- Step 4: write PID file + readiness sentinel + tail forwarder ------------

printf '%s' "$GH_PID" >"$PID_FILE"
: >"$READY_FILE"
printf 'Subscribed. PID file: %s (PID %d)\n' "$PID_FILE" "$GH_PID"
if [[ "$DAEMON_CHILD" == "1" ]]; then
  printf 'Daemon child ready. Parent should now see readiness sentinel: %s\n' "$READY_FILE"
else
  printf 'Watcher running. Press Ctrl-C to stop.\n'
fi
tail -n +1 -f "$GH_LOG" &
TAIL_PID=$!

# --- Step 5: broker + forwarder supervision (foreground) ---------------------
# Periodically probe broker /health; on broker death, respawn with backoff and
# — when a dynamic-port respawn changes the receiver port — relaunch the
# forwarder so events keep reaching the live listener. Runs in the FOREGROUND
# (not a backgrounded subshell) so ghe::restart_forwarder can update GH_PID +
# the PID file in this shell; a subshell's GH_PID assignment would be invisible
# to the reaping below. ghe::supervise_loop (broker-supervisor.sh) returns when
# the forwarder exits. Health-loop tuning is read here and consumed by the lib.

BROKER_HEALTH_INTERVAL="${GITHUB_EVENTS_BROKER_HEALTH_INTERVAL:-30}"
BROKER_BACKOFF_MAX=30
BROKER_STABLE_RESET=300

ghe::supervise_loop

# Forwarder exited — reap it for the exit code, then let the EXIT trap clean up
# (the trap also kills $TAIL_PID, but stop it explicitly so its last lines flush).
wait "$GH_PID" 2>/dev/null
GH_EXIT=$?
kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true

if [[ $GH_EXIT -ne 0 ]]; then
  printf 'gh webhook forward exited with code %d.\n' "$GH_EXIT" >&2
  exit "$GH_EXIT"
fi
exit 0
