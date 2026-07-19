#!/usr/bin/env bash
# GitHub Actions run facts for ci-log-auditor. No raw log bodies.
#
# Output: Run id, Repository, Job lines, Timing billable ms, GitHub API status.
# Exit: 0 on success/graceful degradation; 2 on non-numeric run_id.
set -u

usage() {
  cat <<'EOF'
emit-ci-run-facts.sh — emit Tier-0 CI run facts (no log bodies).

Usage:
  emit-ci-run-facts.sh <run_id>
  emit-ci-run-facts.sh --help

Exit: 0 on success/graceful degradation; 2 on non-numeric run_id.
EOF
}

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

# The conclusion/status/jobs/timing/api facts when run details can't be fetched
# (gh absent, or the repo can't be resolved). Caller prints any Repository line.
emit_unknown_tail() {
  printf 'Run conclusion: unknown\n'
  printf 'Run status: unknown\n'
  printf 'Jobs count: 0\n'
  printf 'Timing billable ms: unavailable\n'
  printf 'GitHub API: unavailable\n'
}

case "${1:-}" in
  -h | --help | "")
    usage
    exit 0
    ;;
esac

run_id="${1:-}"
if ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
  echo "emit-ci-run-facts.sh: run_id must be numeric" >&2
  exit 2
fi

printf 'Run id: %s\n' "$run_id"

if ! command -v gh >/dev/null 2>&1; then
  printf 'Repository: unknown\n'
  emit_unknown_tail
  exit 0
fi

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr -d '\r')"
repo="${repo:-unknown}"
printf 'Repository: %s\n' "$repo"

if [[ "$repo" == "unknown" ]]; then
  emit_unknown_tail
  exit 0
fi

run_json="$(run_bounded 15 gh api "repos/$repo/actions/runs/$run_id" \
  --jq '{conclusion, status}' 2>/dev/null || true)"
conclusion="$(printf '%s' "$run_json" | jq -r '.conclusion // "unknown"' 2>/dev/null | tr -d '\r')"
status="$(printf '%s' "$run_json" | jq -r '.status // "unknown"' 2>/dev/null | tr -d '\r')"
printf 'Run conclusion: %s\n' "${conclusion:-unknown}"
printf 'Run status: %s\n' "${status:-unknown}"

jobs_json="$(run_bounded 15 gh api "repos/$repo/actions/runs/$run_id/jobs" 2>/dev/null || true)"

job_count=0
if [[ -n "$jobs_json" ]]; then
  job_count="$(printf '%s' "$jobs_json" | jq -r '.jobs | length' 2>/dev/null | tr -d '\r')"
  job_count="${job_count:-0}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="$(printf '%s' "$line" | jq -r '.name' 2>/dev/null)"
    jconcl="$(printf '%s' "$line" | jq -r '.conclusion' 2>/dev/null)"
    failed_steps="$(printf '%s' "$line" | jq -r '[.steps[]? | select(.conclusion == "failure")] | length' 2>/dev/null)"
    skipped_steps="$(printf '%s' "$line" | jq -r '[.steps[]? | select(.conclusion == "skipped")] | length' 2>/dev/null)"
    printf 'Job: %s | conclusion=%s | failed_steps=%s | skipped_steps=%s\n' \
      "${name:-unknown}" "${jconcl:-unknown}" "${failed_steps:-0}" "${skipped_steps:-0}"
  done < <(printf '%s' "$jobs_json" | jq -c '.jobs[]?' 2>/dev/null)
fi
printf 'Jobs count: %s\n' "$job_count"

timing_json="$(run_bounded 15 gh api "repos/$repo/actions/runs/$run_id/timing" 2>/dev/null || true)"
billable="$(printf '%s' "$timing_json" | jq -r '.billable_ms // empty' 2>/dev/null | tr -d '\r')"
if [[ -n "$billable" ]]; then
  printf 'Timing billable ms: %s\n' "$billable"
else
  printf 'Timing billable ms: unavailable\n'
fi

printf 'GitHub API: available\n'
exit 0
