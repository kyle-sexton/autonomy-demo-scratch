#!/usr/bin/env bash
# Detect rename pairs from git state (Tier-0 facts for /rename-references smart default).
#
# Sources:
#   - git diff --name-status HEAD — R<score> renames
#   - git diff --cached --name-status — staged renames
#
# Output contract:
#   Rename pair count: <N>
#   Rename pair (<source>): <old> -> <new>
#
# Heuristic paired delete+add is intentionally omitted (high FP); agent uses
# conversation context per rename-references SKILL.md.
#
# Usage:
#   bash tools/rename-references/detect-pair.sh
#   bash tools/rename-references/detect-pair.sh --help
#
# Exit: always 0.
set -u

usage() {
  cat <<'EOF'
detect-pair.sh — emit rename pairs from git R-status lines.

Usage:
  bash tools/rename-references/detect-pair.sh
  detect-pair.sh --help

Exit: 0 (graceful when not in a git repo).
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$repo_root" ]]; then
  echo "Rename pair count: 0"
  echo "Error: not a git repository"
  exit 0
fi
cd "$repo_root" 2>/dev/null || true

pairs=()

collect_renames() {
  local label="$1"
  shift
  local line status rest old new
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status="${line%%$'\t'*}"
    case "$status" in
      R*)
        rest="${line#*$'\t'}"
        old="${rest%%$'\t'*}"
        new="${rest#*$'\t'}"
        pairs+=("Rename pair ($label): $old -> $new")
        ;;
    esac
  done < <("$@" 2>/dev/null | tr -d '\r')
}

collect_renames "diff HEAD" git diff --name-status HEAD
collect_renames "staged" git diff --cached --name-status

echo "Rename pair count: ${#pairs[@]}"
for p in "${pairs[@]}"; do
  echo "$p"
done

exit 0
