#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/list-slug-artifacts.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/list-slug-artifacts.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

# Build a throwaway git repo with derive-slug.sh + script under test.
setup_fake_repo() {
  local repo="$1" branch="$2"
  mkdir -p "$repo/tools/work-artifacts"
  cp "$SCRIPT_DIR/derive-slug.sh" "$repo/tools/work-artifacts/derive-slug.sh"
  cp "$SCRIPT" "$repo/tools/work-artifacts/list-slug-artifacts.sh"
  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name test
    git commit --allow-empty -q -m init
    git checkout -q -b "$branch"
  )
}

# Case 1: no slice dir → fallback message.
repo1="$TEST_TMPDIR/case1"
setup_fake_repo "$repo1" "feat/new-thing"
out=$(cd "$repo1" && bash tools/work-artifacts/list-slug-artifacts.sh PLAN.md)
assert_contains "no-slice fallback names file" "$out" "no prior PLAN.md"
assert_contains "no-slice fallback names slug" "$out" "slug=new-thing"

# Case 2: slice + file exists → ls output.
repo2="$TEST_TMPDIR/case2"
setup_fake_repo "$repo2" "fix/foo-bar"
mkdir -p "$repo2/.work/foo-bar"
echo "x" >"$repo2/.work/foo-bar/PLAN.md"
out=$(cd "$repo2" && bash tools/work-artifacts/list-slug-artifacts.sh PLAN.md)
assert_contains "ls shows PLAN.md" "$out" "PLAN.md"
assert_not_contains "no fallback when present" "$out" "no prior"

# Case 3: slice exists, file missing → fallback.
repo3="$TEST_TMPDIR/case3"
setup_fake_repo "$repo3" "chore/empty"
mkdir -p "$repo3/.work/empty"
out=$(cd "$repo3" && bash tools/work-artifacts/list-slug-artifacts.sh PLAN.md)
assert_contains "missing file → fallback" "$out" "no prior PLAN.md"

# Case 4: multiple args, one exists → ls existing only.
repo4="$TEST_TMPDIR/case4"
setup_fake_repo "$repo4" "feat/two"
mkdir -p "$repo4/.work/two"
echo "x" >"$repo4/.work/two/PRD.md"
out=$(cd "$repo4" && bash tools/work-artifacts/list-slug-artifacts.sh PRD.md PLAN.md)
assert_contains "ls shows PRD.md" "$out" "PRD.md"
assert_not_contains "ls drops missing PLAN.md" "$out" "no prior"

# Case 5: no args → usage error, exit 2.
set +e
out=$(bash "$SCRIPT" 2>&1)
ec=$?
set -e
assert_exit "no-args exit 2" 2 "$ec"
assert_contains "no-args prints usage" "$out" "usage:"

[[ $FAILED -eq 0 ]] || exit 1
echo "All $CASE_NUM checks passed."
