#!/usr/bin/env bash
# tools/github-events/broker-supervisor.sh — broker + forwarder supervision loop.
#
# Co-located single-consumer helper for start-github-watcher.sh (its ONLY caller
# — kept here per shared-code-conventions.md "Rule of one" rather than promoted
# to tools/shared/). Sourced, not executed. Holds the broker + forwarder
# supervision loop as functions so the supervision decision is unit-testable
# with stubs (broker-supervisor.test.sh).
#
# WHY foreground (not a backgrounded subshell): when a dynamic-port broker
# respawns on a NEW receiver port, the running `gh webhook forward` keeps its
# original `--url` and posts to the dead listener (codex 4392612369 / channel-
# gate.sh gate 4 stale-port detection). Self-healing requires relaunching the
# forwarder with the new `--url` AND updating the shared GH_PID / PID file. A
# backgrounded subshell's GH_PID assignment is invisible to the parent that
# reaps it, so supervision MUST run in the shell that owns GH_PID — i.e. the
# foreground after readiness. ghe::supervise_loop returns when the forwarder
# exits; the caller then reaps GH_PID for the exit code.
#
# Caller-provided contract (globals + functions read at CALL time, set by
# start-github-watcher.sh before invoking ghe::supervise_loop):
#   globals (read):  REPO EVENTS WEBHOOK_URL HEALTH_URL GH_PID GH_LOG PID_FILE
#                    PORT_FILE TAIL_PID SUBSCRIBE_RETRIES BROKER_HEALTH_INTERVAL
#                    BROKER_BACKOFF_MAX BROKER_STABLE_RESET PORT BROKER_PORT
#   globals (write): GH_PID GH_LOG TAIL_PID HEALTH_URL WEBHOOK_URL
#                    GHE_BACKOFF GHE_LAST_RESTART
#   env (read):      GITHUB_EVENTS_SKIP_GH — gates the pre-launch hook reconcile
#                    (ghe::ensure_no_stale_cli_hook); set to 1 in tests/no-network
#   functions:       spawn_broker discover_ports (defined in the caller; the
#                    test stubs them)
#   test seam:       GHE_SUPERVISE_MAX_ITERS — cap supervise_loop iterations
#                    (default 0 = unbounded; only the test sets it)
#
# SC2154: the globals above are intentionally caller-provided. Disabled file-
# wide rather than seeded with dummy defaults (which would change behavior).
# shellcheck disable=SC2154

# Include guard — sourcing twice is a no-op (matches broker-prune.sh).
[[ -n "${_GHE_BROKER_SUPERVISOR_SH:-}" ]] && return 0
_GHE_BROKER_SUPERVISOR_SH=1

# Winpid-aware liveness (pid::is_alive). The forwarder ($GH_PID) is a native
# `gh.exe` on Git Bash/Windows whose Windows PID bare `kill -0` CANNOT see, so
# probing it with `kill -0` would report a live forwarder as dead and end
# supervision after the initial grace sleep (codex r3327314231). Same lib +
# rationale as channel-gate.sh gate 4 + broker-prune.sh; pid::is_alive falls back
# to `tasklist` when `kill -0` fails on a Windows shell.
# shellcheck source=../shared/process-management/pid-alive.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/process-management/pid-alive.sh"

# ghe::wait_for_subscription
#
# Block until the current forwarder ($GH_PID, logging to $GH_LOG) confirms its
# subscription, OR it exits early, OR $SUBSCRIBE_RETRIES (1s each) elapse.
# Shared by the watcher's Step 3 (initial launch) and ghe::restart_forwarder
# (relaunch after a broker port change) so both gate on the same signal.
#
# Returns 0 once "subscription established" / "forwarding" appears in $GH_LOG;
# 1 if the forwarder exited before subscribing or the wait timed out.
ghe::wait_for_subscription() {
  local attempt=0
  while ((attempt < SUBSCRIBE_RETRIES)); do
    if grep -qE 'subscription established|forwarding|Forwarding' "$GH_LOG" 2>/dev/null; then
      return 0
    fi
    if ! pid::is_alive "$GH_PID"; then
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

# ghe::kill_and_reap <pid> — signal a child and reap it without ever blocking on
# an unkillable process. On Git Bash/Windows MSYS `kill` cannot reach a native
# gh.exe PID and returns non-zero; `wait` on a still-live, unkillable child would
# then block FOREVER (codex r3327525980). Only `wait` after a successful `kill` —
# a skipped wait leaves at most a short-lived orphan posting to the dead port,
# which exits on its own.
ghe::kill_and_reap() {
  local pid="$1"
  [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && return 0
  if ! pid::is_alive "$pid"; then
    wait "$pid" 2>/dev/null || true
    return 0
  fi
  if kill "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    return 0
  fi
  # MSYS kill cannot signal native gh.exe — escalate on Windows.
  if [[ "${OS:-}" == "Windows_NT" ]] && command -v taskkill >/dev/null 2>&1; then
    taskkill //PID "$pid" //F 2>/dev/null || true
    if ! pid::is_alive "$pid"; then
      wait "$pid" 2>/dev/null || true
    fi
  fi
}

# ghe::ensure_no_stale_cli_hook
#
# `gh webhook forward` CREATES a repo webhook pointing at the GitHub CLI relay
# (webhook-forwarder.github.com) and NEVER deletes it on exit (cli/gh-webhook
# v0.2.0 create_webhook.go — no cleanup, no signal handler). A leftover hook from
# a prior run makes the next `gh webhook forward` fail "422 Hook already exists",
# silently breaking BOTH the initial launch and this lib's ghe::restart_forwarder.
# Reconcile by deleting every pre-existing forwarder hook BEFORE a launch so the
# forwarder always starts from a clean slate (it then recreates a fresh one).
#
# Discriminator: .config.url containing "webhook-forwarder.github.com" — the relay
# endpoint every `gh webhook forward` hook posts to. Verified against live repo
# hook data (the live hook ALSO carries .name=="cli", but the relay URL is the
# more specific match AND survives a gh CLI name-convention change, whereas a
# bare .name=="cli" filter would both miss a renamed hook and risk an unrelated
# "cli"-named hook).
#
# Safe because the caller holds the per-repo watcher lock — this is the sole local
# forwarder, so delete+recreate cannot race a peer. Skipped entirely under
# GITHUB_EVENTS_SKIP_GH=1 (tests / no-network). Per-hook DELETE is best-effort
# (numeric-guarded id). On a `gh api` LIST failure (e.g. the token lacks the
# admin:repo_hook scope) emits an actionable error and returns 1 — the cause is
# surfaced, not swallowed behind the downstream 422.
#
# Reads global REPO (owner/repo). Returns 0 on success (incl. SKIP_GH), 1 on a
# gh api list failure.
ghe::ensure_no_stale_cli_hook() {
  if [[ "${GITHUB_EVENTS_SKIP_GH:-0}" == "1" ]]; then
    return 0
  fi

  local ids rc
  ids="$(gh api "repos/${REPO}/hooks" \
    --jq '.[] | select((.config.url // "") | contains("webhook-forwarder.github.com")) | .id' \
    2>/dev/null)"
  rc=$?
  if ((rc != 0)); then
    printf '[broker-supervisor] ERROR: could not list webhooks for %s (gh api exit %d).\n' "$REPO" "$rc" >&2
    printf '  The gh token likely lacks the admin:repo_hook scope required to read/delete webhooks.\n' >&2
    printf '  Grant it: gh auth refresh -h github.com -s admin:repo_hook\n' >&2
    return 1
  fi
  ids="${ids//$'\r'/}" # strip CR (Git Bash piped output)

  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    [[ "$id" =~ ^[0-9]+$ ]] || continue # numeric-guard: never DELETE a non-id
    if gh api -X DELETE "repos/${REPO}/hooks/${id}" >/dev/null 2>&1; then
      printf '[broker-supervisor] reconciled stale forwarder webhook %s on %s\n' "$id" "$REPO" >&2
    else
      printf '[broker-supervisor] warning: failed to delete stale forwarder webhook %s (best-effort)\n' "$id" >&2
    fi
  done <<<"$ids"
  return 0
}

# ghe::restart_forwarder
#
# Tear down the stale forwarder (and its tail + log), reconcile the stale relay
# hook (ghe::ensure_no_stale_cli_hook — `gh webhook forward` would otherwise 422),
# then relaunch `gh webhook forward` against the CURRENT $WEBHOOK_URL — called when
# a broker respawn changed the receiver port. Uses a fresh log so the
# re-subscription grep starts clean (appending would let a stale "subscription
# established" line false-positive). Publishes the new $GH_PID to $PID_FILE only
# AFTER the relaunched forwarder confirms its subscription (mirrors the watcher's
# Step 3 → Step 4 ordering), so channel-gate.sh / stop-github-watcher.sh never
# track an unsubscribed PID.
#
# Bounded re-subscription check is load-bearing, not belt-and-suspenders: a
# relaunched forwarder that never subscribes would sit alive-but-silent and the
# health loop — seeing a live PID + healthy broker — would treat the link as up,
# relocating the exact event-loss bug this fixes. On failure the forwarder is
# torn down so the loop's next kill -0 catches it and the watcher exits to the
# Monitor fallback.
#
# Returns 0 on a confirmed relaunch, 1 if the relaunched forwarder never
# subscribed (forwarder left dead; $PID_FILE NOT updated).
ghe::restart_forwarder() {
  ghe::kill_and_reap "$GH_PID"
  if [[ -n "${TAIL_PID:-}" ]]; then
    ghe::kill_and_reap "$TAIL_PID"
  fi
  rm -f "${GH_LOG:-}"

  # Reconcile any stale forwarder hook before relaunching — same rationale as the
  # watcher's initial Step 2 launch. The per-repo watcher lock makes this the sole
  # local forwarder, so delete+recreate cannot race a peer. Fail closed: an
  # unrecoverable reconcile (e.g. missing admin:repo_hook scope) aborts the
  # relaunch so the loop exits to the Monitor fallback rather than looping on 422.
  if ! ghe::ensure_no_stale_cli_hook; then
    printf '[broker-supervisor] forwarder relaunch aborted: webhook reconcile failed (see above)\n' >&2
    return 1
  fi

  GH_LOG=$(mktemp)
  gh webhook forward \
    --repo="$REPO" \
    --events="$EVENTS" \
    --url="$WEBHOOK_URL" \
    >"$GH_LOG" 2>&1 &
  GH_PID=$!

  if ! ghe::wait_for_subscription; then
    printf '[broker-supervisor] forwarder re-subscription failed after broker port change:\n' >&2
    sed 's/^/  /' "$GH_LOG" >&2
    ghe::kill_and_reap "$GH_PID"
    return 1
  fi

  printf '%s' "$GH_PID" >"$PID_FILE"
  tail -n +1 -f "$GH_LOG" &
  TAIL_PID=$!
  printf '[broker-supervisor] forwarder restarted on %s (PID %d)\n' "$WEBHOOK_URL" "$GH_PID" >&2
  return 0
}

# ghe::supervise_step
#
# One supervision iteration: probe broker /health; if down, respawn with
# exponential backoff and — when the respawn changed the receiver port —
# relaunch the forwarder against the new URL (ghe::restart_forwarder). Discovers
# the port file first when $HEALTH_URL is unknown (spawn_broker / a prior
# respawn cleared it). Returns 0 normally; returns non-zero when a forwarder
# relaunch fails to re-subscribe, so the loop exits and the watcher's EXIT trap
# clears the PID/ready/lock files immediately. Routine forwarder-death detection
# is still the loop's job (kill -0).
ghe::supervise_step() {
  # Resolve the receiver port if unknown (discover_ports sets HEALTH_URL +
  # WEBHOOK_URL on success). A missing port file leaves HEALTH_URL empty, which
  # falls through to the respawn path below.
  if [[ -z "$HEALTH_URL" ]]; then
    discover_ports || true
  fi

  if [[ -n "$HEALTH_URL" ]] && curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    # Broker healthy — reset backoff once it has been stable long enough.
    local now
    now=$(date +%s)
    if ((GHE_LAST_RESTART > 0 && now - GHE_LAST_RESTART > BROKER_STABLE_RESET)); then
      GHE_BACKOFF=1
    fi
    return 0
  fi

  # Broker down / unreachable — respawn with backoff.
  printf '[broker-supervisor] broker health check failed at %s — restarting (backoff %ds) ...\n' \
    "${HEALTH_URL:-(unknown)}" "$GHE_BACKOFF" >&2
  sleep "$GHE_BACKOFF"
  local prev_webhook_url="$WEBHOOK_URL"
  # Remove the stale port file before respawning: an uncleanly-dead broker leaves
  # broker-*.ports.json behind, and spawn_broker → discover_ports would read those
  # OLD ports immediately (before the new broker writes its real dynamic ports),
  # leaving WEBHOOK_URL == prev and the forwarder un-relaunched — events keep going
  # to the dead receiver. Mirrors start-github-watcher.sh's startup respawn (codex
  # r3327878325).
  rm -f "${PORT_FILE:-}"
  HEALTH_URL=""
  WEBHOOK_URL=""
  if spawn_broker; then
    printf '[broker-supervisor] broker restarted: receiver=%s broker=%s\n' "$PORT" "$BROKER_PORT" >&2
    GHE_LAST_RESTART=$(date +%s)
    # codex 4392612369 L585: a dynamic receiver port may have changed, leaving
    # the running forwarder posting to a dead listener. Relaunch on the new URL.
    # codex r3327000120: if the relaunch cannot re-subscribe, do NOT swallow the
    # failure — propagate it so supervise_loop returns at once and the EXIT trap
    # removes the PID/ready/lock files now. Swallowing it would leave a dead
    # GH_PID + stale PID file + held lock for a full health interval, which
    # channel-mode or a competing invocation could misread as an orphaned lock,
    # and would delay the Monitor fallback.
    if [[ "$WEBHOOK_URL" != "$prev_webhook_url" ]] && ! ghe::restart_forwarder; then
      return 1
    fi
  else
    printf '[broker-supervisor] broker restart failed\n' >&2
  fi

  GHE_BACKOFF=$((GHE_BACKOFF * 2))
  if ((GHE_BACKOFF > BROKER_BACKOFF_MAX)); then
    GHE_BACKOFF=$BROKER_BACKOFF_MAX
  fi
  return 0
}

# ghe::supervise_loop
#
# Foreground supervision: after an initial grace period, probe the broker every
# $BROKER_HEALTH_INTERVAL and stop when the forwarder ($GH_PID) exits. The
# throttle sleep is the LAST statement of every iteration so the healthy path is
# throttled too — a healthy branch that skipped the sleep would spin curl/date
# as a tight busy-loop (codex 4392612369 L575). Returns 0 when the forwarder has
# exited OR when a step signals an unrecoverable relaunch failure; the caller
# reaps $GH_PID for the exit code and the EXIT trap clears the state files.
ghe::supervise_loop() {
  GHE_BACKOFF=1
  GHE_LAST_RESTART=0
  local max_iters="${GHE_SUPERVISE_MAX_ITERS:-0}" iters=0
  sleep 5
  while true; do
    # Forwarder exited (signal, network drop, GH 401)? Stop supervising.
    # Winpid-aware: a native gh.exe forwarder is invisible to bare `kill -0`.
    if ! pid::is_alive "$GH_PID"; then
      return 0
    fi
    # A non-zero step = unrecoverable forwarder loss (a relaunch that never
    # re-subscribed). Stop now so the caller reaps and the EXIT trap clears
    # PID/ready/lock immediately, rather than sleeping a full interval with a
    # dead forwarder + stale PID file (codex r3327000120).
    ghe::supervise_step || return 0
    sleep "$BROKER_HEALTH_INTERVAL"
    if ((max_iters > 0)); then
      iters=$((iters + 1))
      ((iters >= max_iters)) && return 0
    fi
  done
}
