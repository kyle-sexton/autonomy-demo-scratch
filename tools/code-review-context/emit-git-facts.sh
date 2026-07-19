#!/usr/bin/env bash
# Emit Tier-0 git facts for code-review context detection.
#
# Single source of truth for the deterministic fact-gathering that both
# /quality-gate and /code-review-fanout consume. Concern-dir executable per the
# `tools/work-artifacts/derive-slug.sh` precedent (NOT a sourced lib under
# `tools/shared/<capability>/`, which is for shared functions other scripts `source`). LLM
# judgment — mode routing, semantic security-sensitivity, layer-boundary blast
# radius — stays in the consuming skill; this script emits only the hard facts.
#
# Output contract (stable — consumers parse the label prefixes, one fact per label):
#   Current branch: <branch | unknown>
#   Working tree status: <git status --porcelain (first 20) | empty>
#   Recent commits: <git log --oneline -5 | no commits>
#   Changed files (staged+unstaged): <git diff --name-only HEAD | none>
#   Open PR for branch: <number state title | none>
#   Security-sensitive paths touched: <matching changed files | none>
#   Layer-boundary paths touched: <matching changed files | none>
#   Diff size (lines changed, tracked): <N>
#   Review diff base: <HEAD | origin/<default>...HEAD>
#
# "Review diff base" is the ref-spec review surfaces should diff (`git diff <spec>`):
# `HEAD` for a dirty tree (review uncommitted work), or `origin/<default>...HEAD`
# for a clean tree that is ahead of its base (committed branch / open PR — where
# `git diff HEAD` is empty and would make leaf reviewers see nothing).
#
# Usage (CWD-independent — resolve via repo root):
#   bash "$(git rev-parse --show-toplevel | tr -d '\r')/tools/code-review-context/emit-git-facts.sh"
#
# Strict-mode flags are deliberately tuned for a never-crash fact emitter:
#   -e        OMITTED — graceful per-line degradation. `set -e` would abort on the
#             first failing git/gh call, dropping every later fact (e.g. an
#             unauthenticated `gh` would kill the diff-size + path-glob facts that
#             follow it).
#   pipefail  OMITTED — the status fact pipes `git status --porcelain | head -20`.
#             Without pipefail, `head` (which exits 0 on EOF) governs the pipeline
#             exit, so a clean or non-repo state renders an EMPTY status value —
#             matching CC inline-block rendering for empty status (non-repo status renders
#             byte-for-byte (verified 2026-05-29: non-repo status renders empty, not
#             "clean"). `pipefail` would surface git's non-zero exit instead.
#   -u        KEPT — nounset catches authoring bugs; no fact references an unset var
#             (arg parse guards with `${1:-}`).
set -u

usage() {
  cat <<'EOF'
emit-git-facts.sh — emit Tier-0 git facts for code-review context detection.

Prints labeled, deterministic git facts on stdout, one logical fact per label:
  Current branch, Working tree status, Recent commits, Changed files,
  Open PR for branch, Security-sensitive paths touched,
  Layer-boundary paths touched, Diff size (lines changed, tracked),
  Review diff base.

Usage:
  bash "$(git rev-parse --show-toplevel | tr -d '\r')/tools/code-review-context/emit-git-facts.sh"
  emit-git-facts.sh --help

Exit: always 0 (graceful per-line degradation; never crashes a consuming !-block).
Accepts no arguments other than --help / -h.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  *) ;; # any other arg: ignore and emit facts (never-crash contract)
esac

# Run from repo root so path-bearing facts (status, diff, path-glob) are
# cwd-invariant regardless of the caller's working directory or the
# `status.relativePaths` git config. Graceful: outside a repo, stay put and let
# each fact fall back individually.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
[[ -n "$repo_root" ]] && cd "$repo_root" 2>/dev/null || true

# Portable bounded timeout for the one network call (gh). macOS lacks `timeout`
# by default (it ships in GNU coreutils as `gtimeout`) — fall back to gtimeout,
# then to running bare so the fact still degrades via its own `|| echo`.
run_bounded() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

# Resolve the ref-spec review surfaces should diff. Tracked uncommitted changes
# → review the working diff (`HEAD`). Otherwise, a branch ahead of its remote
# default branch → review that range (`origin/<default>...HEAD`), because
# `git diff HEAD` is empty on a committed branch and would make leaf reviewers
# see nothing (the open-PR / committed-branch case). No `gh` dependency — pure
# git, so it degrades to `HEAD` outside a repo or without a remote. Graceful.
#
# The dirtiness test keys on `git diff HEAD` (tracked, staged+unstaged), NOT
# `git status --porcelain`: porcelain also flags UNTRACKED files, which
# `git diff HEAD` cannot show anyway. Keying on porcelain would let an
# incidental untracked scratch file on a committed-ahead branch force `HEAD`,
# diffing an empty working tree and missing the committed PR range entirely.
resolve_review_base() {
  if [[ -n "$(git diff HEAD --name-only 2>/dev/null | head -1)" ]]; then
    echo "HEAD"
    return
  fi
  local default_ref base ahead
  default_ref="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | tr -d '\r')"
  base="${default_ref:-origin/main}"
  if git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    ahead="$(git rev-list --count "$base..HEAD" 2>/dev/null | tr -d '\r')"
    if [[ "$ahead" =~ ^[1-9][0-9]*$ ]]; then
      echo "$base...HEAD"
      return
    fi
  fi
  echo "HEAD"
}

# Patterns are coarse, over-inclusive [EXEC-SHAPE] hints — the consuming skill's
# LLM refines them (a false-positive over-triggers a review lens, which is fail-safe;
# a false-negative is the costly direction). Tune from observed misclassification.
#   Security surface — grounded in repo conventions: auth/identity/credential/secret
#   tokens, CI secrets (`.github/workflows/`), secret-detection hooks
#   (`.claude/hooks/`), app config, the bot-auth wrapper, the banned-symbols policy.
SECURITY_PATTERN='(^|/)(auth|oauth|identity|credential|secret|token|password)|\.github/workflows/|\.claude/hooks/|(^|/)appsettings|github-auth|BannedSymbols|(^|/)\.env($|\.)'
#   Layer-boundary surface — the strict dependency-direction layers (per AGENTS.md
#   "Design defaults") plus the build/analyzer surfaces that enforce them.
LAYER_PATTERN='/(Domain|Application|Infrastructure|Core)/|\.csproj$|(^|/)Directory\.(Build|Packages)\.(props|targets)$|Platform\.Analyzers'

# Capture the changed-file set once — the path-classification facts (security + layer) derive from it.
changed_files="$(git diff --name-only HEAD 2>/dev/null || true)"

security_hits="$(printf '%s\n' "$changed_files" | grep -iE "$SECURITY_PATTERN" || true)"
layer_hits="$(printf '%s\n' "$changed_files" | grep -E "$LAYER_PATTERN" || true)"
diff_size="$(git diff HEAD --numstat 2>/dev/null \
  | awk '{ if ($1 ~ /^[0-9]+$/) added += $1; if ($2 ~ /^[0-9]+$/) deleted += $2 } END { print added + deleted + 0 }')"
review_base="$(resolve_review_base)"

# ---- Core facts ----
# `$( )` strips trailing newlines exactly as CC's inline `!`-block substitution
# does, and the literal `\n` in each format string supplies the per-line newline
# CC takes from the markdown source — so empty facts (non-repo) still terminate
# their line instead of gluing onto the next label.
printf 'Current branch: %s\n' "$(git branch --show-current 2>/dev/null || echo "unknown")"
printf 'Working tree status: %s\n' "$(git status --porcelain 2>/dev/null | head -20)"
printf 'Recent commits: %s\n' "$(git log --oneline -5 2>/dev/null || echo "no commits")"
printf 'Changed files (staged+unstaged): %s\n' "$(git diff --name-only HEAD 2>/dev/null || echo "none")"
printf 'Open PR for branch: %s\n' "$(run_bounded 10 gh pr list --head "$(git branch --show-current 2>/dev/null)" --json number,title,state --jq 'if length > 0 then .[0] | "\(.number) \(.state) \(.title)" else "none" end' 2>/dev/null || echo "none")"

# ---- Additive review-routing signals ----
printf 'Security-sensitive paths touched: %s\n' "${security_hits:-none}"
printf 'Layer-boundary paths touched: %s\n' "${layer_hits:-none}"
printf 'Diff size (lines changed, tracked): %s\n' "${diff_size:-0}"
printf 'Review diff base: %s\n' "${review_base:-HEAD}"
