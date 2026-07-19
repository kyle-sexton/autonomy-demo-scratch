#!/usr/bin/env bash
# Open chore/tidy-* PR count for backlog throttle.
#
# Output: Open tidy PR count, Throttle active, Detail
# Exit: 0 when gh succeeded; 1 when count unknown.
#
# -e omitted: fact-gatherer must capture gh's exit code, not abort on it.
# -o pipefail omitted: graceful degradation when gh/python3 fail mid-pipeline.
set -u

readonly THROTTLE_LIMIT=3

usage() {
  cat <<EOF
open-pr-count.sh — count open chore/tidy-* PRs (backlog throttle facts).

Throttle active when count >= ${THROTTLE_LIMIT} and gh exit 0.

Usage:
  open-pr-count.sh [--help]

Exit: 0 gh ok; 1 gh failed (count unknown).
EOF
}

emit_unknown() {
  printf 'Open tidy PR count: unknown\n'
  printf 'Throttle active: unknown\n'
  printf 'Detail: %s\n' "$1"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  emit_unknown "gh not installed"
  exit 1
fi

json_out="$(gh pr list --state open --search 'head:chore/tidy-' --json number 2>/dev/null)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  emit_unknown "gh exited $rc"
  exit 1
fi

count="$(printf '%s' "$json_out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo unknown)"
if [[ "$count" == unknown ]]; then
  emit_unknown "python3 parse failed"
  exit 1
fi

printf 'Open tidy PR count: %s\n' "$count"
if [[ "$count" -ge "$THROTTLE_LIMIT" ]]; then
  printf 'Throttle active: yes\n'
  printf 'Detail: backlog >= %s\n' "$THROTTLE_LIMIT"
else
  printf 'Throttle active: no\n'
  printf 'Detail: backlog below %s\n' "$THROTTLE_LIMIT"
fi
exit 0
