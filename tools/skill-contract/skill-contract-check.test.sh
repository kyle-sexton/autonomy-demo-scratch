#!/usr/bin/env bash
# Regression tests for tools/skill-contract/skill-contract-check.sh (portability dispatch).
#
# Coverage:
#   - No staged skill files → exit 0 (early-skip gate)
#   - Staged skill with a valid BEHAVIOR.md portability manifest → CLEAN (exit 0, dispatch reached)
#   - Staged skill whose BEHAVIOR.md declares an uncited point → VIOLATION (exit 1)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/skill-contract-check.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

# A fresh test repo's REPO_ROOT has no tools/ tree, so the orchestrator would
# not find the portability verifier it dispatches to. Copy the real verifier in
# so the orchestrator->verifier wiring runs against actual logic (no stub —
# subprocess mocking is a BATS-migration trigger, not the plain-bash regime).
setup_repo() {
  local repo="$TEST_TMPDIR/repo-$CASE_NUM"
  rm -rf "$repo"
  git init --quiet "$repo"
  (
    cd "$repo" || exit 1
    git config user.email "test@example.com"
    git config user.name "test"
    mkdir -p .claude/skills tools/skill-contract
    cp "$SCRIPT_DIR/skill-portability-lib.sh" tools/skill-contract/skill-portability-lib.sh
  )
  echo "$repo"
}

run_hook_in_repo() {
  (cd "$1" && bash "$HOOK" 2>&1)
}

# Seed a skill with a portability BEHAVIOR.md manifest + one behavior point.
# cite_point=1 -> SKILL.md cites the declared point (symmetry satisfied);
# cite_point=0 -> point left uncited (symmetry violation).
seed_portable_skill() {
  local repo="$1" skill_name="$2" cite_point="$3"
  local skill_dir="$repo/.claude/skills/$skill_name"
  local point="$skill_name.sample-point"
  mkdir -p "$skill_dir/behavior/sample-point"

  if [[ "$cite_point" -eq 1 ]]; then
    cat >"$skill_dir/SKILL.md" <<EOF
---
name: $skill_name
description: "Portability dispatch test fixture."
---
Behavior point: <!-- @behavior: $point -->
EOF
  else
    cat >"$skill_dir/SKILL.md" <<EOF
---
name: $skill_name
description: "Portability dispatch test fixture."
---
The declared point is not cited anywhere in this body.
EOF
  fi

  cat >"$skill_dir/BEHAVIOR.md" <<EOF
## Point: $point
Type: text
Default merge: set
File: behavior/sample-point/default.md
Description: Portability dispatch test fixture point.
EOF

  cat >"$skill_dir/behavior/sample-point/default.md" <<EOF
---
'@behavior': $point
merge: set
---
Default content with no repo-specifics.
EOF

  (cd "$repo" && git add .claude/skills/"$skill_name")
}

# CASE 1: No staged skill files → exit 0 (early-skip gate)
repo=$(setup_repo)
(
  cd "$repo" || exit 1
  mkdir -p docs
  echo "unrelated change" >docs/note.md
  git add docs/note.md
)
out=$(run_hook_in_repo "$repo")
rc=$?
assert_eq "case 1 no-skill-files-staged — exit 0" 0 "$rc"
assert_silent "case 1 no-skill-files-staged — silent" "$out"

# CASE 2: Staged skill with a valid portability manifest → CLEAN, dispatch reached
repo=$(setup_repo)
seed_portable_skill "$repo" "portable" 1
out=$(run_hook_in_repo "$repo")
rc=$?
assert_eq "case 2 valid-portability-manifest — exit 0" 0 "$rc"
assert_contains "case 2 valid-portability-manifest — dispatch reached" "$out" "PORTABILITY: PASS"

# CASE 3: Staged skill whose BEHAVIOR.md declares an uncited point → VIOLATION
repo=$(setup_repo)
seed_portable_skill "$repo" "leaky" 0
out=$(run_hook_in_repo "$repo")
rc=$?
assert_eq "case 3 uncited-point — exit 1" 1 "$rc"
assert_contains "case 3 uncited-point — symmetry violation surfaced" "$out" "not cited by SKILL.md"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
