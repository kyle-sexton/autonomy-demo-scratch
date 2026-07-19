#!/usr/bin/env bash
# List existing .work/<slug>/ artifacts for the current branch's slug.
#
# Used by SKILL.md `!`...`` pre-computed-context blocks (e.g. /interview, /prd)
# so the slug derivation + listing is one bash invocation (no `;` chain that
# the permission engine flags as multi-op).
#
# Usage: list-slug-artifacts.sh <filename> [<filename> ...]
#   tools/work-artifacts/list-slug-artifacts.sh PLAN.md
#   tools/work-artifacts/list-slug-artifacts.sh PRD.md PLAN.md
#
# Prints `ls -la` output for each existing path. If none exist, prints a
# single fallback line naming the requested files and the derived slug.

set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $(basename "$0") <filename> [<filename> ...]" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$REPO_ROOT" ]]; then
  echo "not in a git repo"
  exit 0
fi

SLUG="$(bash "$REPO_ROOT/tools/work-artifacts/derive-slug.sh")"
SLICE_DIR="$REPO_ROOT/.work/$SLUG"

existing=()
for f in "$@"; do
  if [[ -e "$SLICE_DIR/$f" ]]; then
    existing+=("$SLICE_DIR/$f")
  fi
done

if [[ ${#existing[@]} -gt 0 ]]; then
  ls -la "${existing[@]}"
else
  echo "no prior $* for slug=$SLUG"
fi
