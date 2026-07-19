#!/usr/bin/env bash
# Anchor commit facts for a tidy lane.
#
# Output: Lane, Anchor SHA, Anchor source, Anchor subject
# Exit: always 0.
#
# -e/-o pipefail omitted: must always exit 0 with best-effort anchor facts, never crash mid-pipeline.
set -u

LANE="${1:-}"

usage() {
  cat <<'EOF'
last-tidy-merge.sh — most recent tidy anchor for a lane.

Usage:
  last-tidy-merge.sh <lane>
  last-tidy-merge.sh --help

Exit: always 0.
EOF
}

case "${LANE}" in
  -h | --help | '')
    usage
    exit 0
    ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
[[ -n "$repo_root" ]] && cd "$repo_root" || true

printf 'Lane: %s\n' "$LANE"

sha=""
source="none"
subject="n/a"

if command -v gh >/dev/null 2>&1; then
  pr_json="$(gh pr list --state merged --search "head:chore/tidy-${LANE}-" --json mergedAt,mergeCommit,title --limit 1 2>/dev/null || true)"
  if [[ -n "$pr_json" && "$pr_json" != "[]" ]]; then
    read -r sha subject < <(printf '%s' "$pr_json" | python3 -c '
import json, sys
items = json.load(sys.stdin)
if not items:
    sys.exit(0)
item = items[0]
sha = (item.get("mergeCommit") or {}).get("oid") or ""
title = item.get("title") or ""
print(sha, title)
' 2>/dev/null)
    if [[ -n "$sha" ]]; then
      source="merged-pr"
    fi
  fi
fi

if [[ -z "$sha" ]]; then
  sha="$(git log --grep="chore(tidy):.*${LANE}" -1 --format='%H' 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$sha" ]]; then
    source="grep-commit"
    subject="$(git log -1 --format='%s' "$sha" 2>/dev/null | tr -d '\r')"
  fi
fi

printf 'Anchor SHA: %s\n' "${sha:-none}"
printf 'Anchor source: %s\n' "$source"
printf 'Anchor subject: %s\n' "$subject"
