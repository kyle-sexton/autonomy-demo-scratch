#!/usr/bin/env bash
# Pre-commit guard: NEW skill scripts and NEW tools-unit root entry scripts
# must ship with both --help support AND a co-located <file>.test.sh.
#
# Scope (NEW files only — see cleanliness-regime.md "Skill script contract"):
#   - git diff --cached --diff-filter=A --name-only
#   - filter to:
#       .claude/skills/<X>/scripts/*.sh
#       tools/<unit>/*.sh   (unit root entry scripts only — not */lib/*)
#   - exclude */lib/*, */scaffolds/*, *.test.sh, *-test-helpers.sh, *.template.sh
#   - classify by first line (unit-anatomy.md "Entry vs. sourceable discriminator"):
#       bash shebang             → ENTRY script
#       `# shellcheck shell=bash` → SOURCEABLE contract lib (no shebang)
#       anything else            → skipped (non-bash / data file, no contract)
#
# Per-candidate assertions:
#   1. sibling <file>.test.sh exists in working tree (both kinds)
#   2. `bash <file> --help` exits 0 with non-empty stdout (ENTRY scripts only;
#      sourceables are sourced, never invoked, so the --help contract is waived)
#
# Existing (un-modified) scripts that lack either contract are out of scope.
# Backfill cohort routed via /work-items add at sub-slice closure (PLAN Phase 2
# disposition decision; not silent debt).
#
# Kill switch: HOOK_SKILL_SCRIPT_CONTRACT_CHECK_ENABLED=false skips entirely.
#
# SSOT: .claude/rules/cleanliness-regime.md "Skill script contract"
#       (filter design + NEW-only scope + backfill-cohort disposition)

set -uo pipefail

if [[ "${HOOK_SKILL_SCRIPT_CONTRACT_CHECK_ENABLED:-true}" != "true" ]]; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r') || exit 0
cd "$REPO_ROOT" || exit 1

# Collect NEW files (staged Adds). filter-design exclusions applied below.
mapfile -t added < <(git diff --cached --diff-filter=A --name-only 2>/dev/null)

if [[ ${#added[@]} -eq 0 ]]; then
  exit 0
fi

candidates=()
kinds=()
for f in "${added[@]}"; do
  # Skill-script or tools-unit root entry path filter
  case "$f" in
    .claude/skills/*/scripts/*.sh) ;;
    tools/*/*.sh) ;;
    *) continue ;;
  esac
  # Name-based exclusions (test sibling, test helpers, templates)
  case "$f" in
    *.test.sh) continue ;;
    *-test-helpers.sh) continue ;;
    *.template.sh) continue ;;
  esac
  # Path-based exclusions (sourced libs, scaffolding data)
  case "$f" in
    */lib/*) continue ;;
    */scaffolds/*) continue ;;
  esac
  # Entry-vs-sourceable discriminator (unit-anatomy.md "Entry vs. sourceable
  # discriminator"): a bash shebang marks an ENTRY script (sibling test +
  # --help); a leading `# shellcheck shell=bash` directive with no shebang
  # marks a SOURCEABLE contract lib (sibling test, --help waived — it is
  # sourced, never invoked). Anything else (non-bash shebang, data file with
  # no directive) carries no contract and is skipped.
  first_line=$(head -n1 "$f" 2>/dev/null)
  case "$first_line" in
    '#!/usr/bin/env bash' | '#!/bin/bash')
      candidates+=("$f")
      kinds+=("entry")
      ;;
    '# shellcheck shell=bash'*)
      candidates+=("$f")
      kinds+=("sourceable")
      ;;
    *) continue ;;
  esac
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  exit 0
fi

violations=()
for i in "${!candidates[@]}"; do
  f="${candidates[$i]}"
  kind="${kinds[$i]}"
  test_sibling="${f%.sh}.test.sh"
  if [[ ! -f "$test_sibling" ]]; then
    violations+=("$f: missing sibling test file ($test_sibling)")
    continue
  fi

  # Sourceable contract libs are sourced, never invoked — sibling test is the
  # whole contract; the --help assertion below applies to entry scripts only.
  if [[ "$kind" == "sourceable" ]]; then
    continue
  fi

  help_out=$(bash "$f" --help 2>&1 </dev/null)
  help_rc=$?
  if [[ $help_rc -ne 0 ]]; then
    violations+=("$f: --help exited $help_rc (expected 0)")
    continue
  fi
  if [[ -z "$help_out" ]]; then
    violations+=("$f: --help produced empty stdout")
    continue
  fi
done

if [[ ${#violations[@]} -eq 0 ]]; then
  exit 0
fi

echo "skill-script-contract-check: ${#violations[@]} violation(s) found." >&2
echo "NEW skill scripts and NEW tools/<unit>/*.sh entry scripts must ship with --help AND a sibling <file>.test.sh." >&2
echo "See .claude/rules/cleanliness-regime.md \"Skill script contract\"." >&2
echo "" >&2
for v in "${violations[@]}"; do
  echo "  $v" >&2
done
echo "" >&2
echo "Fix: add --help case to the script + author <file>.test.sh, then re-commit." >&2
exit 1
