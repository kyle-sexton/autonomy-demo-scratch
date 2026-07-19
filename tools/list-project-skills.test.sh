#!/usr/bin/env bash
# Regression tests for tools/list-project-skills.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
# shellcheck source=../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

FAILED=0
CASE_NUM=0

# Fixture skill: first project skill present on disk — decoupled from any real
# skill name so plugin-migration cutovers deleting skills cannot break this test.
FIXTURE_SKILL=$(basename "$(dirname "$(find "$REPO_ROOT/.claude/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | sort | head -1)")")

out=$(bash "$REPO_ROOT/tools/list-project-skills.sh" 2>&1)
assert_contains "markdown header" "$out" "| Skill | Description |"
assert_contains "lists first skill" "$out" "| $FIXTURE_SKILL |"

out_tsv=$(bash "$REPO_ROOT/tools/list-project-skills.sh" --tsv 2>&1)
assert_contains "tsv first skill name" "$out_tsv" "$FIXTURE_SKILL"$'\t'

out_bad=$(bash "$REPO_ROOT/tools/list-project-skills.sh" --nope 2>&1) && rc=0 || rc=$?
assert_eq "unknown flag exits 2" 2 "$rc"
assert_contains "unknown flag usage" "$out_bad" "Usage:"

[[ $FAILED -eq 0 ]] || exit 1
