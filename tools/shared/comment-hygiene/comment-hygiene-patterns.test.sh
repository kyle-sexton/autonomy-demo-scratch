#!/usr/bin/env bash
# Regression tests for tools/shared/comment-hygiene/comment-hygiene-patterns.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=comment-hygiene-patterns.sh
source "$SCRIPT_DIR/comment-hygiene-patterns.sh"

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# --- should_skip_path ---
chp::should_skip_path "review/code-quality.md"
assert_exit "skip review slice" 0 $?

chp::should_skip_path "apps/foo/Bar.cs"
assert_exit "do not skip production cs" 1 $?

chp::should_skip_path ".work/slice/PLAN.md"
assert_exit "skip work slice" 0 $?

scan_expect() {
  local expect_rc="$1"
  local label="$2"
  local content="$3"
  local rc=0
  chp::scan_text "$content" >/dev/null 2>&1 || rc=$?
  assert_exit "$label" "$expect_rc" "$rc"
}

scan_expect 0 "todo in hash comment clean" $'x=1\n'
out=$(chp::scan_text $'# TODO: add tests\n' 2>&1) || true
assert_contains "todo marker in output" "$out" "warning-marker"

scan_expect 1 "todo in hash comment fails" $'# TODO: add tests\n'
scan_expect 1 "todo in slash comment fails" $'// TODO: ship later\n'
scan_expect 0 "issue string in code is clean" $'assert x "issue:#1234"\n'
scan_expect 0 "encapsulation audit marker allowed" $'# TODO(encapsulation-audit): missing /foo\n'

out=$(chp::scan_text $'# See cc-issue #27343 for contract.\n' 2>&1) || true
scan_expect 1 "cc-issue in comment fails" $'# See cc-issue #27343 for contract.\n'
assert_contains "tracker ref kind" "$out" "tracker-ref"

scan_expect 0 "external repo#issue allowed" $'// Tracked: anthropics/claude-code#11897 proxy bug.\n'
scan_expect 0 "upstream dotnet repo#issue allowed" $'// dotnet/roslyn#24319: shared ErrorLog path.\n'
scan_expect 0 "bare upstream issue numbers allowed" $'# #39702 / #35059 misclassification.\n'
scan_expect 0 "vendor support issue allowed" $'// Duende Support #789 teardown race.\n'
scan_expect 1 "internal repo#issue fails" $'// Fix in melodic-software/medley#42.\n'
scan_expect 1 "pr ref in comment fails" $'// Cycle hardening (PR #831): details.\n'
scan_expect 0 "roslyn markup not a comment" $'var x = {|#0:Name|};\n'

scan_expect 0 "phase token sequence allowed" $'# --- Phases: mixed DONE+DOING+TODO → in-progress ---\n'
scan_expect 0 "bracket phase tag allowed" $'# Case 11: plan scaffold (Brief + Plan + [TODO] phase)\n'

echo "comment-hygiene-patterns.test.sh: all cases passed"
