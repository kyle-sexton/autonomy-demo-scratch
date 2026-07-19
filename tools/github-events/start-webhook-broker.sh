#!/usr/bin/env bash
# tools/github-events/start-webhook-broker.sh — Foreground supervisor for the github-events broker.
#
# Spawns `node mcp-servers/github-events/node/build/broker/index.js`, waits for the
# `/health` endpoint to respond 200, then tails the broker's stderr until the
# user presses Ctrl-C. On exit, sends SIGINT to the broker so it cleans up its
# own lockfile + PID file (managed inside the broker process — see
# `src/broker/index.ts`).
#
# Single-instance enforcement is handled by the broker itself: a second
# `start-webhook-broker.sh` invocation will see the broker exit with
# "another broker already running" and exit 0 without further action.
#
# Usage:
#   tools/github-events/start-webhook-broker.sh                # foreground; blocks until Ctrl-C
#   tools/github-events/start-webhook-broker.sh --dry-run      # print plan, exit 0
#
# Env overrides:
#   GITHUB_EVENTS_PORT          default 8788 (receive port — `gh webhook forward` posts here)
#   GITHUB_EVENTS_BROKER_PORT   default 8789 (subscribe port — subscribers SSE-connect here)
#   GITHUB_EVENTS_HEALTH_RETRIES default 30 (1s each)
#   GITHUB_EVENTS_BROKER_ENTRY  override the broker JS path (test/dev-tree)
#
# Exit codes:
#   0  normal shutdown OR --dry-run OR broker reported "another broker already running"
#   1  broker /health unreachable after retries
#   2  broker exited unexpectedly before /health came up
#   3  invalid argument
#   4  prerequisite missing (node or build artifact)

# Omit -e: explicit exit-code checks on broker spawn + health probe.
set -uo pipefail

# shellcheck source=../shared/process-management/pid-alive.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-alive.sh"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  -h | --help)
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *)
    printf 'start-webhook-broker: unknown argument %q (use --help)\n' "$1" >&2
    exit 3
    ;;
esac

PORT="${GITHUB_EVENTS_PORT:-8788}"
BROKER_PORT="${GITHUB_EVENTS_BROKER_PORT:-8789}"
HEALTH_RETRIES="${GITHUB_EVENTS_HEALTH_RETRIES:-30}"
HEALTH_URL="http://127.0.0.1:${PORT}/health"
VERSION_URL="http://127.0.0.1:${BROKER_PORT}/version"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
BROKER_ENTRY="${GITHUB_EVENTS_BROKER_ENTRY:-${REPO_ROOT}/mcp-servers/github-events/node/build/broker/index.js}"

print_plan() {
  printf 'github-events broker plan\n'
  printf '  receive port:   %s (POST /webhook from gh-webhook-forward)\n' "$PORT"
  printf '  subscribe port: %s (SSE /subscribe for CC subscribers)\n' "$BROKER_PORT"
  printf '  health url:     %s\n' "$HEALTH_URL"
  printf '  version url:    %s\n' "$VERSION_URL"
  printf '  broker entry:   %s\n' "$BROKER_ENTRY"
  printf '  health retries: %s (1s each)\n' "$HEALTH_RETRIES"
}

if [[ $DRY_RUN -eq 1 ]]; then
  print_plan
  printf 'Dry-run complete. Re-run without --dry-run to start the broker.\n'
  exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

if ! have node; then
  printf 'start-webhook-broker: node required (see /onboard Phase 0)\n' >&2
  exit 4
fi

if ! have curl; then
  printf 'start-webhook-broker: curl required (see /onboard Phase 0)\n' >&2
  exit 4
fi

if [[ ! -f "$BROKER_ENTRY" ]]; then
  printf 'start-webhook-broker: broker entry not found: %s\n' "$BROKER_ENTRY" >&2
  printf '  Build it with: cd mcp-servers/github-events/node && npm run build\n' >&2
  exit 4
fi

print_plan

# --- Spawn the broker, capture stderr ---------------------------------------

BROKER_LOG=$(mktemp)
cleanup() {
  local pid="${BROKER_PID:-}"
  if [[ -n "$pid" ]] && pid::is_alive "$pid"; then
    kill -INT "$pid" 2>/dev/null || true
    # Give the broker 3s to release its lockfile + PID file before forcing.
    local i=0
    while ((i < 30)); do
      pid::is_alive "$pid" || break
      sleep 0.1
      i=$((i + 1))
    done
    if pid::is_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$BROKER_LOG"
}
trap cleanup EXIT INT TERM

printf 'Starting broker ...\n'
GITHUB_EVENTS_PORT="$PORT" GITHUB_EVENTS_BROKER_PORT="$BROKER_PORT" \
  node "$BROKER_ENTRY" >"$BROKER_LOG" 2>&1 &
BROKER_PID=$!

# --- Wait for /health ---------------------------------------------------------

attempt=0
healthy=0
while ((attempt < HEALTH_RETRIES)); do
  # Broker exited (e.g. lock held by another instance, or crash)
  if ! pid::is_alive "$BROKER_PID"; then
    if grep -q 'another broker already running' "$BROKER_LOG"; then
      printf 'Broker reports another instance is already running:\n' >&2
      sed 's/^/  /' "$BROKER_LOG" >&2
      # Detach from cleanup — broker self-released, nothing to kill.
      BROKER_PID=""
      exit 0
    fi
    printf 'ERROR: broker exited before /health came up. Output:\n' >&2
    sed 's/^/  /' "$BROKER_LOG" >&2
    exit 2
  fi

  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    healthy=1
    printf '  /health OK (after %ds)\n' "$attempt"
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [[ $healthy -ne 1 ]]; then
  printf 'ERROR: broker /health unreachable on port %s after %ds.\n' "$PORT" "$HEALTH_RETRIES" >&2
  sed 's/^/  /' "$BROKER_LOG" >&2
  exit 1
fi

printf 'Broker running (PID %d). Press Ctrl-C to stop.\n' "$BROKER_PID"
printf '----- broker stderr -----\n'
tail -n +1 -f "$BROKER_LOG" &
TAIL_PID=$!

# Wait for the broker to exit (signal or crash).
wait "$BROKER_PID"
BROKER_EXIT=$?
BROKER_PID=""
kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true

if [[ $BROKER_EXIT -ne 0 ]]; then
  printf 'Broker exited with code %d.\n' "$BROKER_EXIT" >&2
  exit "$BROKER_EXIT"
fi
exit 0
