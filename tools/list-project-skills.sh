#!/usr/bin/env bash
# List project skill frontmatter (name + description) from .claude/skills/*/SKILL.md.
# For Cursor when Third-party skills import is off or slash commands are missing.
#
# Usage:
#   bash tools/list-project-skills.sh           # markdown table on stdout
#   bash tools/list-project-skills.sh --tsv     # name<TAB>description

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
[[ -n "$REPO_ROOT" ]] || {
  echo "list-project-skills: not inside a git repo" >&2
  exit 1
}

# shellcheck source=skill-contract/skill-frontmatter.sh
source "$REPO_ROOT/tools/skill-contract/skill-frontmatter.sh"

FORMAT=markdown
if [[ "${1:-}" == "--tsv" ]]; then
  FORMAT=tsv
elif [[ -n "${1:-}" ]]; then
  echo "Usage: bash tools/list-project-skills.sh [--tsv]" >&2
  exit 2
fi

shopt -s nullglob
skill_files=("$REPO_ROOT"/.claude/skills/*/SKILL.md)
shopt -u nullglob

if ((${#skill_files[@]} == 0)); then
  echo "list-project-skills: no SKILL.md files under .claude/skills/" >&2
  exit 1
fi

if [[ "$FORMAT" == markdown ]]; then
  printf '| Skill | Description |\n| --- | --- |\n'
fi

while IFS= read -r skill_md; do
  [[ -f "$skill_md" ]] || continue
  fm=$(skill_frontmatter::extract <"$skill_md")
  [[ -n "$fm" ]] || continue
  name=$(skill_frontmatter::strip_quotes "$(skill_frontmatter::field name <<<"$fm")")
  desc=$(skill_frontmatter::strip_quotes "$(skill_frontmatter::field description <<<"$fm")")
  [[ -n "$name" ]] || continue
  if [[ "$FORMAT" == tsv ]]; then
    printf '%s\t%s\n' "$name" "$desc"
  else
    desc=${desc//|/\\|}
    printf '| %s | %s |\n' "$name" "$desc"
  fi
done < <(printf '%s\n' "${skill_files[@]}" | LC_ALL=C sort)
