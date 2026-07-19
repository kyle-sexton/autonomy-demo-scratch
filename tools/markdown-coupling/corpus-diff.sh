#!/usr/bin/env bash
# Branch-changed durable-corpus .md paths for quality-gate restatement scope.
#
# Output: Diff base, Review head, In-scope file lines, In-scope count
# Exit: always 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=corpus-scope.sh
source "${SCRIPT_DIR}/corpus-scope.sh"

BASE_REF="origin/main"

usage() {
  cat <<'EOF'
corpus-diff.sh — branch delta intersected with durable instruction corpus.

Uses corpus-scope.sh SCOPE_RE / NOISE_RE (same family as check-heading-cites).

Usage:
  corpus-diff.sh [--base <ref>]
  corpus-diff.sh --help

Exit: always 0.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE_REF="${2:-origin/main}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "corpus-diff: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$repo_root" ]]; then
  echo "Diff base: unknown"
  echo "In-scope count: 0"
  exit 0
fi
cd "$repo_root" || exit 0

head_sha="$(git rev-parse HEAD 2>/dev/null | tr -d '\r' || echo unknown)"
base_sha="$(git merge-base "$BASE_REF" HEAD 2>/dev/null | tr -d '\r' || echo unknown)"

printf 'Diff base: %s\n' "$base_sha"
printf 'Review head: %s\n' "$head_sha"

count=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  [[ "$path" == .work/* ]] && continue
  if [[ "$path" =~ $NOISE_RE ]]; then
    continue
  fi
  if [[ "$path" =~ $SCOPE_RE ]]; then
    printf 'In-scope file: %s\n' "$path"
    count=$((count + 1))
  fi
done < <(git diff --name-only "$base_sha"...HEAD -- '*.md' 2>/dev/null | tr -d '\r' | sort)

printf 'In-scope count: %s\n' "$count"
