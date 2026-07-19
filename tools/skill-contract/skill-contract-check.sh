#!/usr/bin/env bash
# Pre-commit skill contract gate.
#
# Check (on staged skill surface only):
#   Portability — BEHAVIOR.md symmetry, defaults, deny-list (via skill-portability-lib.sh)
#
# Kill switch: HOOK_SKILL_CONTRACT_CHECK_ENABLED=false
# Legacy kill switch still honored for partial disable:
#   HOOK_SKILL_PORTABILITY_CHECK_ENABLED=false
#
# SSOT: .claude/rules/skill/encapsulation.md

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')" || exit 0
[[ -d "$REPO_ROOT" ]] || exit 0

if [[ "${HOOK_SKILL_CONTRACT_CHECK_ENABLED:-true}" != "true" ]]; then
  exit 0
fi

PORTABILITY_ENABLED="${HOOK_SKILL_PORTABILITY_CHECK_ENABLED:-true}"
FULL_TREE="${SKILL_GOVERNANCE_CI_FULL_TREE:-false}"

staged="$(git diff --cached --name-only)"

affected_skills=()

if [[ "$FULL_TREE" == "true" ]]; then
  if [[ -d "$REPO_ROOT/.claude/skills" ]]; then
    mapfile -t affected_skills < <(
      for skill_dir in "$REPO_ROOT/.claude/skills"/*/; do
        [[ -d "$skill_dir" ]] || continue
        basename "$skill_dir"
      done | grep -E '^[a-z][a-z0-9-]+$' | sort -u
    )
  fi
else
  [[ -n "$staged" ]] || exit 0

  mapfile -t affected_skills < <(
    printf '%s\n' "$staged" \
      | grep -E '^\.claude/skills/[a-z][a-z0-9-]+/(SKILL\.md|BEHAVIOR\.md|behavior/)' \
      | sed -E 's|^\.claude/skills/([a-z][a-z0-9-]+)/.*|\1|' \
      | sort -u
  )

  [[ "${#affected_skills[@]}" -eq 0 ]] && exit 0
fi

failures=0

run_portability_check() {
  local verifier="$REPO_ROOT/tools/skill-contract/skill-portability-lib.sh"
  if [[ ! -f "$verifier" ]]; then
    return 0
  fi

  local skill skill_dir
  for skill in "${affected_skills[@]}"; do
    skill_dir="$REPO_ROOT/.claude/skills/$skill"
    [[ -f "$skill_dir/BEHAVIOR.md" ]] || continue
    if ! bash "$verifier" "$skill"; then
      failures=$((failures + 1))
    fi
  done
}

if [[ "$PORTABILITY_ENABLED" == "true" && "${#affected_skills[@]}" -gt 0 ]]; then
  run_portability_check
fi

if [[ "$failures" -gt 0 ]]; then
  echo ""
  echo "See .claude/rules/skill/encapsulation.md."
  exit 1
fi

exit 0
