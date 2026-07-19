#!/usr/bin/env bash
# Regression tests for tools/skill-contract/skill-frontmatter.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/skill-frontmatter.sh"

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel | tr -d '\r')/tests/shell/lib.sh"

# shellcheck source=skill-frontmatter.sh
source "$LIB"

out="$(printf '%s\n' '---' 'name: demo' 'description: "quoted"' '---' 'body' | skill_frontmatter::extract)"
assert_contains "extract returns frontmatter body" "$out" "name: demo"
assert_contains "extract includes description" "$out" "description:"

name="$(printf '%s\n' '---' 'name: demo-skill' '---' | skill_frontmatter::extract | skill_frontmatter::field name)"
name="$(skill_frontmatter::strip_quotes "$name")"
assert_eq "field + strip_quotes" "demo-skill" "$name"

triggers="$(printf 'Use %s or %s\n' "'foo bar'" "'foo bar'" | skill_frontmatter::extract_triggers)"
trigger_count="$(printf '%s\n' "$triggers" | grep -c . || true)"
assert_eq "extract_triggers dedupes" "1" "$trigger_count"
assert_contains "extract_triggers keeps phrase" "$triggers" "'foo bar'"

contraction_triggers="$(printf "can't verify broken code (prose). Use when: 'real trigger'\n" | skill_frontmatter::extract_triggers)"
contraction_count="$(printf '%s\n' "$contraction_triggers" | grep -c . || true)"
assert_eq "extract_triggers ignores contraction apostrophes" "1" "$contraction_count"
assert_contains "extract_triggers keeps real phrase alongside contraction" "$contraction_triggers" "'real trigger'"

echo "skill-frontmatter.test.sh: $((CASE_NUM - FAILED)) passed, ${FAILED} failed"
[[ "$FAILED" -eq 0 ]] || exit 1
