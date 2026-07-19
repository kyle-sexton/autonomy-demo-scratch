#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/work-encapsulation-check.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/work-encapsulation-check.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

run_hook_with_files() {
  # Run hook from a per-case tmpdir so file-path args resolve cleanly.
  local case_dir="$1"
  shift
  (cd "$case_dir" && bash "$HOOK" "$@" 2>&1)
}

make_file() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
}

# Case 1: no staged files -> silent, exit 0
out=$(bash "$HOOK" 2>&1)
assert_silent "no-staged-files: silent" "$out"
assert_exit "no-staged-files: exit 0" 0 $?

# Case 2: forbidden concrete pointer -> warning surfaced, exit 1 (blocking)
case_dir="$TEST_TMPDIR/case-forbidden"
make_file "$case_dir/notes.md" "See \`.work/real-slice/PLAN.md\` for the plan."
out=$(run_hook_with_files "$case_dir" "notes.md")
rc=$?
assert_contains "forbidden: warning emitted" "$out" "work-encapsulation:"
assert_contains "forbidden: cites the pointer" "$out" ".work/real-slice/PLAN.md"
assert_exit "forbidden: exit 1 blocking" 1 $rc

# Case 3: ALLOW git-log retrieval form -> silent
case_dir="$TEST_TMPDIR/case-gitlog"
make_file "$case_dir/history.md" "Slice deleted; retrieve via \`git log -- .work/real-slice/\`."
out=$(run_hook_with_files "$case_dir" "history.md")
assert_silent "git-log-form: silent" "$out"

# Case 4: ALLOW angle-bracket placeholder schema -> silent
case_dir="$TEST_TMPDIR/case-schema"
make_file "$case_dir/convention.md" "Every slice lives at \`.work/<slug>/PLAN.md\` and \`.work/<audit-slug>/README.md\`."
out=$(run_hook_with_files "$case_dir" "convention.md")
assert_silent "angle-bracket-schema: silent" "$out"

# Case 5: ALLOW shell variable forms -> silent
case_dir="$TEST_TMPDIR/case-vars"
make_file "$case_dir/script-ref.md" "Writes to .work/\$SLUG/PLAN.md and .work/\${slug}/journal/."
out=$(run_hook_with_files "$case_dir" "script-ref.md")
assert_silent "shell-var-schema: silent" "$out"

# Case 6: ALLOW example/pedagogical slugs -> silent
case_dir="$TEST_TMPDIR/case-examples"
make_file "$case_dir/teach.md" "e.g. \`.work/foo/PLAN.md\`, \`.work/sample-slice/README.md\`, \`.work/scratch/notes.md\`."
out=$(run_hook_with_files "$case_dir" "teach.md")
assert_silent "example-slugs: silent" "$out"

# Case 7: ALLOW machinery file (work-artifacts* rule) -> silent
case_dir="$TEST_TMPDIR/case-machinery"
make_file "$case_dir/work-artifacts.md" "The gate looks for \`.work/real-slice/verify/x.md\`."
out=$(run_hook_with_files "$case_dir" "work-artifacts.md")
assert_silent "machinery-rule: silent" "$out"

# Case 8: ALLOW *.test.sh fixtures -> silent
case_dir="$TEST_TMPDIR/case-testfixture"
make_file "$case_dir/something.test.sh" "log_dir=\"\$case_dir/.work/real-slice/log\""
out=$(run_hook_with_files "$case_dir" "something.test.sh")
assert_silent "test-fixture: silent" "$out"

# Case 9: ALLOW lint-config file -> silent
case_dir="$TEST_TMPDIR/case-lintconfig"
make_file "$case_dir/_typos.toml" "\".work/real-slice/log/\","
out=$(run_hook_with_files "$case_dir" "_typos.toml")
assert_silent "lint-config: silent" "$out"

# Case 10: HAZARD — line carries a git-log clause for one slug AND a bare pointer
# for another. The bare pointer MUST still be flagged (precise strip-then-check).
case_dir="$TEST_TMPDIR/case-hazard"
make_file "$case_dir/mixed.md" "See \`.work/real-slice/PLAN.md\` (others: \`git log -- .work/other-slice/\`)."
out=$(run_hook_with_files "$case_dir" "mixed.md")
assert_contains "both-on-one-line: bare pointer still flagged" "$out" ".work/real-slice/PLAN.md"

# Case 11: file UNDER .work/ is out of scope -> silent (slice-internal cross-refs are legal)
case_dir="$TEST_TMPDIR/case-inwork"
make_file "$case_dir/.work/some-slice/PLAN.md" "depends on \`.work/real-slice/PLAN.md\`"
out=$(run_hook_with_files "$case_dir" ".work/some-slice/PLAN.md")
assert_silent "in-work-scope: silent" "$out"

# Case 12: kill switch disables the lane entirely -> silent
case_dir="$TEST_TMPDIR/case-killswitch"
make_file "$case_dir/notes.md" "See \`.work/real-slice/PLAN.md\`."
out=$(HOOK_WORK_ENCAPSULATION_CHECK_ENABLED=false run_hook_with_files "$case_dir" "notes.md")
assert_silent "kill-switch: silent" "$out"

# Case 13: clean file -> silent, exit 0
case_dir="$TEST_TMPDIR/case-clean"
make_file "$case_dir/clean.md" "Nothing references the work directory here."
out=$(run_hook_with_files "$case_dir" "clean.md")
assert_silent "clean-file: silent" "$out"

# Case 14: multiple files, only some violate -> only the violator is flagged
case_dir="$TEST_TMPDIR/case-mixed-files"
make_file "$case_dir/bad.md" "See \`.work/real-slice/PLAN.md\`."
make_file "$case_dir/good.md" "Retrieve via \`git log -- .work/real-slice/\`."
out=$(run_hook_with_files "$case_dir" "bad.md" "good.md")
assert_contains "mixed-files: bad.md flagged" "$out" "bad.md"
assert_not_contains "mixed-files: good.md not flagged" "$out" "good.md,"

[[ $FAILED -eq 0 ]] || exit 1
