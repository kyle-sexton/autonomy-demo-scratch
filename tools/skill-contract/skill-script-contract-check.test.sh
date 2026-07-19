#!/usr/bin/env bash
# Regression tests for tools/skill-contract/skill-script-contract-check.sh.
#
# Coverage:
#   - NEW script with sibling test + --help → PASS (exit 0)
#   - NEW script missing sibling test → VIOLATION (exit 1)
#   - NEW script with --help rc!=0 → VIOLATION
#   - NEW script with --help empty stdout → VIOLATION
#   - Modified (not added) script missing contract → PASS (option 3 NEW-only)
#   - *.test.sh added → PASS (excluded by name filter)
#   - */lib/* added → PASS (excluded by path filter)
#   - */scaffolds/* added → PASS (excluded by path filter)
#   - *-test-helpers.sh added → PASS (excluded by name filter)
#   - *.template.sh added → PASS (excluded by name filter)
#   - Script without bash shebang AND no shellcheck directive → PASS (skipped)
#   - NEW sourceable lib (no shebang + `# shellcheck shell=bash`) + sibling test
#     → PASS (sourceable contract: sibling test required, --help NOT)
#   - NEW sourceable lib without sibling test → VIOLATION
#   - Kill switch HOOK_SKILL_SCRIPT_CONTRACT_CHECK_ENABLED=false → PASS
#   - Empty stage → PASS

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/skill-script-contract-check.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

# Build a throwaway repo with the named files staged-Add. Each fixture seeds
# its own files via callback so cases can shape contract compliance.
setup_repo() {
  local repo="$TEST_TMPDIR/repo-$CASE_NUM"
  rm -rf "$repo"
  git init --quiet "$repo"
  (
    cd "$repo" || exit 1
    git config user.email "test@example.com"
    git config user.name "test"
    mkdir -p .claude/skills/sample/scripts
  )
  echo "$repo"
}

stage_new_script() {
  # $1=repo $2=relpath $3=body
  local repo="$1" rel="$2" body="$3"
  mkdir -p "$repo/$(dirname "$rel")"
  printf '%s' "$body" >"$repo/$rel"
  (cd "$repo" && git add -- "$rel")
}

stage_modify_script() {
  # $1=repo $2=relpath $3=initial-body $4=modified-body
  local repo="$1" rel="$2" initial="$3" modified="$4"
  mkdir -p "$repo/$(dirname "$rel")"
  printf '%s' "$initial" >"$repo/$rel"
  (cd "$repo" && git add -- "$rel" && git commit --quiet -m "seed: $rel")
  printf '%s' "$modified" >"$repo/$rel"
  (cd "$repo" && git add -- "$rel")
}

run_hook_in_repo() { (cd "$1" && bash "$HOOK" 2>&1); }

# --- Helpers: script bodies ---
GOOD_BODY=$'#!/usr/bin/env bash\nif [[ "${1:-}" == "--help" ]]; then echo "Usage: foo.sh [--help]"; exit 0; fi\necho ok\n'
NO_HELP_BODY=$'#!/usr/bin/env bash\necho "no help support"\nexit 0\n'
HELP_FAILS_BODY=$'#!/usr/bin/env bash\nif [[ "${1:-}" == "--help" ]]; then echo "err"; exit 2; fi\n'
HELP_EMPTY_BODY=$'#!/usr/bin/env bash\nif [[ "${1:-}" == "--help" ]]; then exit 0; fi\n'
NO_SHEBANG_BODY=$'echo "data file or fragment"\n'
TEST_BODY=$'#!/usr/bin/env bash\n# placeholder test\nexit 0\n'
# Sourceable contract lib: no shebang, `# shellcheck shell=bash` directive,
# no --help support — proves the sourceable branch waives the --help contract.
SOURCEABLE_BODY=$'# shellcheck shell=bash\n# Sourceable contract lib for unit U.\nu_helper() { echo "lib fn"; }\n'

# --- Case 1: hook parses ---
if ! bash -n "$HOOK"; then
  fail "hook parses" "exit 0" "syntax error"
else
  pass "hook parses with bash -n"
fi

# --- Case 2: NEW script + sibling test + --help support → PASS ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/good.sh" "$GOOD_BODY"
stage_new_script "$repo" ".claude/skills/sample/scripts/good.test.sh" "$TEST_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 2 (compliant new script): exit 0" 0 "$rc"
assert_not_contains "case 2: no violation msg" "$out" "violation(s) found"

# --- Case 3: NEW script + NO sibling test → VIOLATION ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/lonely.sh" "$GOOD_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 3 (missing test): exit 1" 1 "$rc"
assert_contains "case 3: violation msg" "$out" "violation(s) found"
assert_contains "case 3: names missing test" "$out" "missing sibling test"

# --- Case 4: NEW script + --help non-zero exit → VIOLATION ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/helpfail.sh" "$HELP_FAILS_BODY"
stage_new_script "$repo" ".claude/skills/sample/scripts/helpfail.test.sh" "$TEST_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 4 (--help rc!=0): exit 1" 1 "$rc"
assert_contains "case 4: cites --help exited" "$out" "--help exited"

# --- Case 5: NEW script + --help empty stdout → VIOLATION ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/helpempty.sh" "$HELP_EMPTY_BODY"
stage_new_script "$repo" ".claude/skills/sample/scripts/helpempty.test.sh" "$TEST_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 5 (--help empty stdout): exit 1" 1 "$rc"
assert_contains "case 5: cites empty stdout" "$out" "empty stdout"

# --- Case 6: MODIFIED script (not Added) missing contract → PASS (option 3) ---
repo=$(setup_repo)
stage_modify_script "$repo" ".claude/skills/sample/scripts/existing.sh" \
  "$NO_HELP_BODY" "$NO_HELP_BODY"$'\n# extra line\n'
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 6 (modified script grandfathered): exit 0" 0 "$rc"
assert_not_contains "case 6: no violation msg" "$out" "violation(s) found"

# --- Case 7: *.test.sh added → PASS (excluded by name filter) ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/orphan.test.sh" "$TEST_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 7 (*.test.sh excluded): exit 0" 0 "$rc"

# --- Case 8: */lib/* added → PASS (sourced lib, not entry-point) ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/lib/util.sh" "$NO_HELP_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 8 (lib/ excluded): exit 0" 0 "$rc"

# --- Case 9: */scaffolds/* added → PASS (data/template content) ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/scaffolds/blocks.sh" "$NO_HELP_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 9 (scaffolds/ excluded): exit 0" 0 "$rc"

# --- Case 10: *-test-helpers.sh added → PASS (sourced helper lib) ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/foo-test-helpers.sh" "$NO_HELP_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 10 (*-test-helpers.sh excluded): exit 0" 0 "$rc"

# --- Case 11: *.template.sh added → PASS (template content) ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/foo.template.sh" "$NO_HELP_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 11 (*.template.sh excluded): exit 0" 0 "$rc"

# --- Case 12: script without bash shebang → PASS (non-bash entry-point) ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/nodejs.sh" "$NO_SHEBANG_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 12 (no shebang excluded): exit 0" 0 "$rc"

# --- Case 13: kill switch disables enforcement ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/lonely2.sh" "$GOOD_BODY"
kill_out=$(cd "$repo" && HOOK_SKILL_SCRIPT_CONTRACT_CHECK_ENABLED=false bash "$HOOK" 2>&1)
kill_rc=$?
assert_exit "case 13 (kill switch): exit 0" 0 "$kill_rc"
assert_not_contains "case 13: no violation msg" "$kill_out" "violation(s) found"

# --- Case 14: empty stage → PASS ---
repo=$(setup_repo)
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 14 (empty stage): exit 0" 0 "$rc"

# --- Case 15: NEW sourceable lib (no shebang + shellcheck directive) + sibling
#     test → PASS (sourceable contract: sibling test required, --help waived) ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/contract.sh" "$SOURCEABLE_BODY"
stage_new_script "$repo" ".claude/skills/sample/scripts/contract.test.sh" "$TEST_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 15 (sourceable lib + test): exit 0" 0 "$rc"
assert_not_contains "case 15: no violation msg" "$out" "violation(s) found"

# --- Case 16: NEW sourceable lib WITHOUT sibling test → VIOLATION ---
repo=$(setup_repo)
stage_new_script "$repo" ".claude/skills/sample/scripts/orphan-lib.sh" "$SOURCEABLE_BODY"
out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
assert_exit "case 16 (sourceable lib missing test): exit 1" 1 "$rc"
assert_contains "case 16: names missing test" "$out" "missing sibling test"

[[ $FAILED -eq 0 ]] || exit 1
echo "All $CASE_NUM cases passed."
