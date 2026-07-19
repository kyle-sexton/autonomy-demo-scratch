#!/usr/bin/env bash
# Instruction-surface drift facts: rules inventory, headings, orphan paths.
#
# Output: labeled facts on stdout. Exit: always 0.
#
# Output contract:
#   Rules file count: <N>
#   Rules file: <path>                    (sorted, one per line)
#   AGENTS top-level heading: <title>       (## only, file order)
#   CLAUDE top-level heading: <title>
#   CLAUDE includes AGENTS: yes|no
#   Orphan rules (uncited): <path|none>     (not referenced in AGENTS.md/CLAUDE.md/README.md)
#
# Usage:
#   bash tools/verification/check-agents-claude-drift.sh
#   check-agents-claude-drift.sh --help
set -u

usage() {
  cat <<'EOF'
check-agents-claude-drift.sh — emit instruction-surface drift facts.

Prints rules inventory, top-level heading lists, and orphan rule paths.

Usage:
  check-agents-claude-drift.sh
  check-agents-claude-drift.sh --help

Exit: always 0.
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
  echo "Rules file count: 0"
  echo "Error: not a git repository"
  exit 0
fi
cd "$repo_root" || exit 0

mapfile -t rules < <(find .claude/rules -type f -name '*.md' 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)
printf 'Rules file count: %s\n' "${#rules[@]}"
for rule in "${rules[@]}"; do
  printf 'Rules file: %s\n' "$rule"
done

extract_h2() {
  local file="$1" prefix="$2"
  grep -E '^## ' "$file" 2>/dev/null | sed 's/^## //' | while IFS= read -r title; do
    title="${title//$'\r'/}"
    printf '%s: %s\n' "$prefix" "$title"
  done
}

if [[ -f AGENTS.md ]]; then
  extract_h2 AGENTS.md "AGENTS top-level heading"
fi
if [[ -f CLAUDE.md ]]; then
  extract_h2 CLAUDE.md "CLAUDE top-level heading"
  if grep -qE '^@AGENTS\.md' CLAUDE.md 2>/dev/null; then
    printf 'CLAUDE includes AGENTS: yes\n'
  else
    printf 'CLAUDE includes AGENTS: no\n'
  fi
fi

corpus="$(cat AGENTS.md CLAUDE.md README.md 2>/dev/null | tr -d '\r')"
orphans=()
for rule in "${rules[@]}"; do
  if ! grep -qF "$rule" <<<"$corpus"; then
    orphans+=("$rule")
  fi
done

if [[ "${#orphans[@]}" -eq 0 ]]; then
  printf 'Orphan rules (uncited): none\n'
else
  for rule in "${orphans[@]}"; do
    printf 'Orphan rules (uncited): %s\n' "$rule"
  done
fi

exit 0
