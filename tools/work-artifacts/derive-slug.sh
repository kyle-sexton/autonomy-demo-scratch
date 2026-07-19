#!/usr/bin/env bash
# Derive the .work/<slug>/ slug from the current git branch.
#
# Canonical formula per `.claude/rules/work-artifacts/conventions.md` "Slug derivation":
# branch name without type prefix, kebab-case, 40-char cap; falls back to
# timestamp on main / detached HEAD / outside a git repo.
#
# Single source of truth for the formula. SKILL.md `!`...`` pre-computed-context
# blocks and bash scripts both call this rather than inlining the pipeline.
#
# Usage (from anywhere — CWD-independent):
#   SLUG=$(bash "$(git rev-parse --show-toplevel | tr -d '\r')/tools/work-artifacts/derive-slug.sh")
#
# Or from a script that already resolved REPO_ROOT:
#   SLUG=$(bash "$REPO_ROOT/tools/work-artifacts/derive-slug.sh")

set -uo pipefail

slug=$(git branch --show-current 2>/dev/null | sed 's|.*/||' | tr ' _' '-' | cut -c1-40)
# Fall back to timestamp on main/master (no task slug yet) and on
# detached/no-repo states (empty `git branch --show-current`).
if [[ -z "$slug" || "$slug" == "main" || "$slug" == "master" ]]; then
  slug="task-$(date +%Y%m%d-%H%M)"
fi

printf '%s\n' "$slug"
