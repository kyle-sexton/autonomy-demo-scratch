#!/usr/bin/env bash
REPO_ROOT="${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

SCAFFOLD="$REPO_ROOT/tools/agent-loop/scripts/scaffold-slice-harness.sh"
FIXTURE_SLUG="agent-loop-scaffold-fixture"
SLICE_ROOT="$REPO_ROOT/.work/$FIXTURE_SLUG"

teardown() {
  rm -rf "$SLICE_ROOT"
}

trap teardown EXIT

teardown
mkdir -p "$REPO_ROOT/.work"

bash "$SCAFFOLD" --slug "$FIXTURE_SLUG" --phases 2 --out-subdir ".work/$FIXTURE_SLUG/out"
assert_exit "scaffold exits 0" 0 $?

assert_file_exists "run-phase.sh" "$SLICE_ROOT/scripts/run-phase.sh"
assert_file_exists "verify-common.sh" "$SLICE_ROOT/scripts/verify-common.sh"
assert_file_exists "verify-phase-1.sh" "$SLICE_ROOT/scripts/verify-phase-1.sh"
assert_file_exists "verify-phase-2.sh" "$SLICE_ROOT/scripts/verify-phase-2.sh"
assert_file_exists "implement-shared-rules" "$SLICE_ROOT/research/implement-shared-rules.prompt.md"
assert_file_exists "implement-phase-1" "$SLICE_ROOT/research/implement-phase-1.prompt.md"
assert_file_exists "pilot-audit" "$SLICE_ROOT/research/agent-loop-pilot-audit.md"

assert_contains "run id env" "$(cat "$SLICE_ROOT/scripts/run-phase.sh")" "agent-loop-scaffold-fixture-p\${PHASE}"

echo "marker" >"$SLICE_ROOT/research/implement-phase-1.prompt.md"
bash "$SCAFFOLD" --slug "$FIXTURE_SLUG" --phases 2
assert_exit "scaffold no-clobber exits 0" 0 $?
assert_contains "no-clobber prompt" "$(cat "$SLICE_ROOT/research/implement-phase-1.prompt.md")" "marker"

if bash "$SCAFFOLD" --slug '../../outside' --phases 1 2>/dev/null; then
  fail "scaffold should reject path traversal slug"
else
  pass "scaffold rejects path traversal slug"
fi

pass "scaffold-slice-harness"

[[ $FAILED -eq 0 ]] || exit 1
