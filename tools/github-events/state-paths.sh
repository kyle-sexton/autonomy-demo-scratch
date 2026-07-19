# shellcheck shell=bash
# tools/github-events/state-paths.sh — SSOT for github-events daemon state-file paths.
#
# Single source of truth for WHERE the broker port file, watcher PID file, and
# related state live. Sourced by both the daemon supervisor
# (start-github-watcher.sh) and the channel-mode activation gate
# (channel-gate.sh) so the two can NEVER drift — the drift that the 2026-05-28
# babysit/PR-process audit found (the documented activation gate probed
# ${TMPDIR}/... while the live daemon wrote ${LOCALAPPDATA}/github-events/...,
# false-negating a live daemon on every platform).
#
# Slug is the REPO IDENTITY (owner/repo), NOT the worktree directory name. A
# GitHub repo has exactly one webhook + one `gh webhook forward` watcher, so all
# worktrees AND clones of one repo MUST resolve to the SAME broker + watcher
# state — otherwise each worktree spawns its own broker while the single watcher
# feeds only one, leaving the rest healthy-but-starved. Identity is resolved from
# GITHUB_EVENTS_REPO, else parsed from `git remote get-url origin` (offline,
# stable across worktrees since they share the remote). Per repo = 1 watcher +
# 1 broker; isolated across repos (watcher pid/lock + broker port file all
# slugged), shared across worktrees/clones.
#
# Cross-language note: the Node broker (mcp-servers/github-events/node/src/shared/env.ts
# parseRemoteUrl() + repoIdentity() + repoSlug()) mirrors this same convention in
# TypeScript. The two CANNOT share code (different runtimes) but MUST agree on the
# contract BYTE-FOR-BYTE — a divergent slug makes the MCP subscriber read the wrong
# port file and channel mode silently dies. The shared parity harness
# (tools/github-events/slug-parity.test.sh) gates that agreement.
#   Windows:      %LOCALAPPDATA%/github-events/
#   Linux/macOS:  $XDG_STATE_HOME/github-events/  (default ~/.local/state/github-events/)
#   port file:    broker-<repo-slug>.ports.json
#   watcher pid:  watcher-<repo-slug>.pid  (+ .ready sentinel, .lock dir)
#
# This is a LIBRARY — not executable, no side effects (no mkdir, no exit). The
# caller decides whether to create STATE_DIR. Sourcing pattern (per
# bash/conventions.md "Cross-tool shared libraries"):
#   source "$(dirname "${BASH_SOURCE[0]}")/state-paths.sh"
#   ghe::resolve_state_paths
#
# After ghe::resolve_state_paths, the following globals are set (all overridable
# via the matching GITHUB_EVENTS_* env var, identical semantics to the prior
# inline derivation in start-github-watcher.sh):
#   GHE_STATE_DIR   GHE_REPO_IDENTITY   GHE_REPO_SLUG   GHE_PID_FILE
#   GHE_READY_FILE  GHE_LOCK_DIR        GHE_PORT_FILE

# Include guard — sourcing twice is a no-op.
[[ -n "${_GHE_STATE_PATHS_SH:-}" ]] && return 0
_GHE_STATE_PATHS_SH=1

# Derive the github-events state directory (platform-conditional, env-overridable).
# Mirrors stateDir() in env.ts. Survives Windows Storage Sense temp cleanup
# unlike $TMPDIR (the reason the audit-found drift mattered).
ghe::state_dir() {
  if [[ "${OS:-}" == "Windows_NT" && -n "${LOCALAPPDATA:-}" ]]; then
    printf '%s' "${GITHUB_EVENTS_STATE_DIR:-${LOCALAPPDATA}/github-events}"
  else
    printf '%s' "${GITHUB_EVENTS_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/github-events}"
  fi
}

# Parse a git remote URL to `owner/repo`. PURE — string in, no child process, so
# it is unit-testable without a real remote and drives the cross-language parity
# harness. Mirrors parseRemoteUrl() in env.ts byte-for-byte:
#   strip CR + trailing ".git", replace ':' with '/', take the last two non-empty
#   '/'-delimited segments joined by '/'.
# Handles every common origin form:
#   git@github.com:owner/repo.git          -> owner/repo   (SCP/SSH short)
#   ssh://git@github.com/owner/repo.git    -> owner/repo
#   https://github.com/owner/repo.git      -> owner/repo
#   https://github.com/owner/repo          -> owner/repo
# Returns empty when fewer than two segments resolve (caller falls back to the
# sentinel slug).
ghe::parse_remote_url() {
  local url="${1:-}"
  url="${url//$'\r'/}" # strip any CR (Git Bash piped output)
  url="${url%.git}"    # strip a single trailing .git
  url="${url//:/\/}"   # ':' -> '/' (collapses git@host:owner/repo and scheme '://')
  [[ "$url" == */* ]] || return 0
  local -a raw=() filtered=()
  local seg
  IFS='/' read -ra raw <<<"$url"
  for seg in "${raw[@]}"; do
    [[ -n "$seg" ]] && filtered+=("$seg")
  done
  local n=${#filtered[@]}
  ((n >= 2)) || return 0
  printf '%s/%s' "${filtered[n - 2]}" "${filtered[n - 1]}"
}

# Resolve the repo identity (owner/repo) the watcher targets. Priority:
#   1. GITHUB_EVENTS_REPO env (already owner/repo form) — what gh webhook forward --repo uses.
#   2. parse `git remote get-url origin` (offline; shared across worktrees/clones).
#   3. empty — caller maps empty slug to the sentinel.
# Mirrors repoIdentity() in env.ts.
ghe::repo_identity() {
  if [[ -n "${GITHUB_EVENTS_REPO:-}" ]]; then
    printf '%s' "$GITHUB_EVENTS_REPO"
    return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null | tr -d '\r')"
  ghe::parse_remote_url "$url"
}

# Derive the sanitized repo slug used for the per-repo broker port file + watcher
# pid/lock names. Override via GITHUB_EVENTS_REPO_SLUG (explicit escape hatch,
# highest priority); else sanitize the repo identity. Sanitization mirrors env.ts
# sanitizeSlug: [^A-Za-z0-9_-] -> '-', trim leading/trailing dashes ('/' in
# owner/repo becomes '-', so melodic-software/medley -> melodic-software-medley).
# No case normalization — both languages read the SAME shared origin, so case is
# identical; lowercasing would add a divergence surface for zero benefit.
ghe::repo_slug() {
  if [[ -n "${GITHUB_EVENTS_REPO_SLUG:-}" ]]; then
    # Sanitize the override too — mirrors env.ts sanitizeSlug, and prevents a
    # crafted slug (e.g. "../evil") from path-traversing the state-file name.
    printf '%s' "$GITHUB_EVENTS_REPO_SLUG" | tr -d '\r' | sed 's/[^A-Za-z0-9_-]/-/g; s/^-*//; s/-*$//'
    return 0
  fi
  local identity
  identity="$(ghe::repo_identity)"
  printf '%s' "$identity" | tr -d '\r' | sed 's/[^A-Za-z0-9_-]/-/g; s/^-*//; s/-*$//'
}

# Resolve every state path into GHE_* globals. Side-effect-free (no mkdir).
# Env-var overrides match start-github-watcher.sh's prior inline behavior 1:1.
# shellcheck disable=SC2034  # GHE_* are this lib's OUTPUT CONTRACT — consumed by
# sourcing scripts (start-github-watcher.sh, channel-gate.sh), invisible to a
# standalone lint of this file.
ghe::resolve_state_paths() {
  GHE_STATE_DIR="$(ghe::state_dir)"
  GHE_REPO_IDENTITY="$(ghe::repo_identity)"
  GHE_REPO_SLUG="$(ghe::repo_slug)"
  # Guard empty slug. ghe::repo_slug returns empty when the override sanitizes to
  # nothing (e.g. "---") or no identity resolves (no GITHUB_EVENTS_REPO + no origin
  # remote). An empty slug would collapse the state files to "broker-.ports.json" /
  # "watcher-.pid", which every such context would then share. The TS mirror
  # (env.ts repoSlug) returns the same "unknown-repo" sentinel on the no-identity
  # path; bash is a side-effect-free resolver, so it falls back here — neither side
  # ever produces the shared empty-slug path.
  [[ -z "$GHE_REPO_SLUG" ]] && GHE_REPO_SLUG="unknown-repo"
  GHE_PID_FILE="${GITHUB_EVENTS_PID_FILE:-${GHE_STATE_DIR}/watcher-${GHE_REPO_SLUG}.pid}"
  GHE_READY_FILE="${GHE_PID_FILE}.ready"
  GHE_LOCK_DIR="${GITHUB_EVENTS_LOCK_DIR:-${GHE_PID_FILE}.lock}"
  GHE_PORT_FILE="${GHE_STATE_DIR}/broker-${GHE_REPO_SLUG}.ports.json"
}
