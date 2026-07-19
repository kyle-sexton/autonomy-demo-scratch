#!/usr/bin/env bash
# Family A path-exclude drift gate — anchor patterns must appear in all three consumers.
#
# SSOT: docs/conventions/search-hygiene.md "Exclude families"
#
# Usage:
#   check-path-exclude-families.sh
#   check-path-exclude-families.sh --help
#
# Exit: 0 all anchors present; 1 drift detected.
set -uo pipefail

usage() {
  cat <<'EOF'
check-path-exclude-families.sh — verify Family A exclude anchors across consumers.

Checks that core skill/generated path patterns appear in .ignore,
.cursorindexingignore, and _typos.toml extend-exclude.

Usage:
  check-path-exclude-families.sh
  check-path-exclude-families.sh --help

Exit: 0 pass; 1 missing anchor in a consumer file.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  *)
    ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')" || {
  echo "check-path-exclude-families.sh: not a git repository" >&2
  exit 1
}
cd "$repo_root" || exit 1

IGNORE_FILE=".ignore"
INDEX_FILE=".cursorindexingignore"
TYPOS_FILE="_typos.toml"

family_a_anchors=(
  ".claude/skills/course-digest/data/"
  ".claude/skills/onlocation/references/"
)

family_c_anchors=(
  ".claude/observability/"
  "tools/agent-loop/logs/"
)

check_anchor() {
  local file="$1" anchor="$2"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: missing file $file" >&2
    return 1
  fi
  if ! grep -Fq "$anchor" "$file"; then
    echo "FAIL: $file missing anchor: $anchor" >&2
    return 1
  fi
  return 0
}

failed=0

for anchor in "${family_a_anchors[@]}"; do
  check_anchor "$IGNORE_FILE" "$anchor" || failed=1
  check_anchor "$INDEX_FILE" "$anchor" || failed=1
  check_anchor "$TYPOS_FILE" "$anchor" || failed=1
done

for anchor in "${family_c_anchors[@]}"; do
  check_anchor "$IGNORE_FILE" "$anchor" || failed=1
  check_anchor "$INDEX_FILE" "$anchor" || failed=1
done

if [[ ! -f "$INDEX_FILE" ]] || ! grep -Fq '**/*COMPLETE_DATABASE*.json' "$INDEX_FILE"; then
  echo "FAIL: $INDEX_FILE missing anchor: **/*COMPLETE_DATABASE*.json" >&2
  failed=1
fi
if [[ ! -f "$IGNORE_FILE" ]] || ! grep -Fq '**/*COMPLETE_DATABASE*.json' "$IGNORE_FILE"; then
  echo "FAIL: $IGNORE_FILE missing anchor: **/*COMPLETE_DATABASE*.json" >&2
  failed=1
fi

if [[ $failed -ne 0 ]]; then
  echo "See docs/conventions/search-hygiene.md \"Exclude families\"" >&2
  exit 1
fi

echo "OK: path exclude families (Family A + C anchors) in sync"
