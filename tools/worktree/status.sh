#!/usr/bin/env bash
# Emit Tier-0 worktree inventory facts for /worktree status and audit.
#
# Parses `git worktree list --porcelain` and optional `gh pr list` cross-reference.
# Judgment (recommendations, cleanup confirmation) stays in the worktree skill.
#
# Output contract (stable label prefixes, one fact block per worktree):
#   Worktree count: <N>
#   Worktree <i> path: <path>
#   Worktree <i> branch: <branch | detached>
#   Worktree <i> flags: <comma-separated: prunable,locked,detached | none>
#   Worktree <i> last commit: <ISO8601 | unknown>
#   Worktree <i> PR: <#N STATE title | none>
#   GitHub API: <available | unavailable>
#
# Usage:
#   bash tools/worktree/status.sh
#   bash tools/worktree/status.sh --help
#
# Env:
#   WORKTREE_STALE_DAYS — informational only in summary line (default 14)
#
# Exit: always 0 (graceful degradation like emit-git-facts.sh).
set -u

usage() {
  cat <<'EOF'
status.sh — emit Tier-0 worktree inventory facts.

Prints labeled worktree facts on stdout for /worktree status and audit.
Judgment and cleanup actions stay in the worktree skill.

Usage:
  bash tools/worktree/status.sh
  status.sh --help

Env:
  WORKTREE_STALE_DAYS  Staleness threshold for summary hint (default 14)

Exit: always 0.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

stale_days="${WORKTREE_STALE_DAYS:-14}"
if ! [[ "$stale_days" =~ ^[0-9]+$ ]]; then
  stale_days=14
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$repo_root" ]]; then
  echo "Worktree count: 0"
  echo "Error: not a git repository"
  exit 0
fi
cd "$repo_root" 2>/dev/null || true

porcelain="$(git worktree list --porcelain 2>/dev/null | tr -d '\r')"
if [[ -z "$porcelain" ]]; then
  echo "Worktree count: 0"
  exit 0
fi

# Optional PR map: branch -> "#num STATE title"
declare -A pr_by_branch=()
gh_status="unavailable"
if command -v gh >/dev/null 2>&1; then
  pr_json="$(gh pr list --state all --json number,title,state,headRefName --limit 200 2>/dev/null || true)"
  if [[ -n "$pr_json" ]]; then
    gh_status="available"
    while IFS=$'\t' read -r branch num state title; do
      [[ -z "$branch" ]] && continue
      pr_by_branch["$branch"]="#${num} ${state} ${title}"
    done < <(printf '%s' "$pr_json" | jq -r '.[] | [.headRefName, .number, .state, .title] | @tsv' 2>/dev/null)
  fi
fi

# Parse porcelain entries (blank-line separated)
entries=()
current=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ -z "$line" ]]; then
    [[ -n "$current" ]] && entries+=("$current")
    current=""
  else
    current+="${line}"$'\n'
  fi
done <<<"$porcelain"
[[ -n "$current" ]] && entries+=("$current")

echo "Worktree count: ${#entries[@]}"
echo "GitHub API: $gh_status"
echo "Stale threshold days: $stale_days"

idx=0
for entry in "${entries[@]}"; do
  idx=$((idx + 1))
  wt_path=""
  branch=""
  flags=()
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        wt_path="${line#worktree }"
        ;;
      branch\ refs/heads/*)
        branch="${line#branch refs/heads/}"
        ;;
      detached)
        flags+=("detached")
        branch="detached"
        ;;
      locked*)
        flags+=("locked")
        ;;
      prunable*)
        flags+=("prunable")
        ;;
    esac
  done <<<"$entry"

  [[ -z "$branch" ]] && branch="detached"
  flag_str="none"
  if [[ ${#flags[@]} -gt 0 ]]; then
    flag_str=$(
      IFS=,
      echo "${flags[*]}"
    )
  fi

  last_commit="unknown"
  if [[ -n "$branch" && "$branch" != "detached" ]]; then
    last_commit="$(git log -1 --format='%ci' "$branch" 2>/dev/null | tr -d '\r' || echo unknown)"
    [[ -z "$last_commit" ]] && last_commit="unknown"
  fi

  pr_line="none"
  if [[ -n "$branch" && "$branch" != "detached" && -n "${pr_by_branch[$branch]+x}" ]]; then
    pr_line="${pr_by_branch[$branch]}"
  fi

  echo "Worktree $idx path: ${wt_path:-unknown}"
  echo "Worktree $idx branch: $branch"
  echo "Worktree $idx flags: $flag_str"
  echo "Worktree $idx last commit: $last_commit"
  echo "Worktree $idx PR: $pr_line"
done

exit 0
