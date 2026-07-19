#!/usr/bin/env bash
# shellcheck disable=SC2154
# Regression tests for tools/derive-slug.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/derive-slug.sh"

# Per-case isolation: each case runs inside its own temp git repo so we can
# control branch state (typed prefix, main, detached HEAD, no-repo).
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# --- Case 1: typed branch prefix is stripped ---

REPO1="$TEST_TMPDIR/repo1"
make_repo "$REPO1"
(cd "$REPO1" && git checkout -q -b feat/example-feature)
OUT=$(cd "$REPO1" && bash "$SCRIPT")
assert_eq "feat/example-feature → example-feature" "example-feature" "$OUT"

# --- Case 2: branch with no slash returns as-is ---

REPO2="$TEST_TMPDIR/repo2"
make_repo "$REPO2"
(cd "$REPO2" && git checkout -q -b some-branch)
OUT=$(cd "$REPO2" && bash "$SCRIPT")
assert_eq "some-branch (no prefix) → some-branch" "some-branch" "$OUT"

# --- Case 3: 40-char cap ---

REPO3="$TEST_TMPDIR/repo3"
make_repo "$REPO3"
# Branch description is 50 chars after prefix; expect truncation to 40
(cd "$REPO3" && git checkout -q -b "feat/aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeee")
OUT=$(cd "$REPO3" && bash "$SCRIPT")
assert_eq "long branch → 40 chars" "aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd" "$OUT"
assert_eq "long branch → length 40" "40" "${#OUT}"

# --- Case 4: spaces and underscores normalized to hyphens ---

REPO4="$TEST_TMPDIR/repo4"
make_repo "$REPO4"
(cd "$REPO4" && git checkout -q -b "fix/name_with_underscores")
OUT=$(cd "$REPO4" && bash "$SCRIPT")
assert_eq "underscores → hyphens" "name-with-underscores" "$OUT"

# --- Case 5: outside a git repo falls back to task-<timestamp> ---

OUTSIDE="$TEST_TMPDIR/not-a-repo"
mkdir -p "$OUTSIDE"
OUT=$(cd "$OUTSIDE" && bash "$SCRIPT")
# Format: task-YYYYMMDD-HHMM (length 18). Just match the prefix; full timestamp
# would be brittle in cross-second runs.
assert_contains "no git repo → task- fallback" "$OUT" "task-"
# Verify the timestamp shape: task- followed by 8 digits, hyphen, 4 digits
if [[ "$OUT" =~ ^task-[0-9]{8}-[0-9]{4}$ ]]; then
  pass "no git repo → task-YYYYMMDD-HHMM shape"
else
  fail "no git repo → task-YYYYMMDD-HHMM shape" "task-YYYYMMDD-HHMM" "$OUT"
fi

# --- Case 6: detached HEAD falls back to task-<timestamp> ---

REPO6="$TEST_TMPDIR/repo6"
make_repo "$REPO6"
# Detach HEAD by checking out the commit SHA directly
(cd "$REPO6" && git checkout -q --detach HEAD)
OUT=$(cd "$REPO6" && bash "$SCRIPT")
if [[ "$OUT" =~ ^task-[0-9]{8}-[0-9]{4}$ ]]; then
  pass "detached HEAD → task-YYYYMMDD-HHMM"
else
  fail "detached HEAD → task-YYYYMMDD-HHMM" "task-YYYYMMDD-HHMM" "$OUT"
fi

# --- Case 7: cloud-agent prefixes (claude/, codex/, cursor/, copilot/) ---

REPO7="$TEST_TMPDIR/repo7"
make_repo "$REPO7"
(cd "$REPO7" && git checkout -q -b "claude/test-setup-script-v56UV")
OUT=$(cd "$REPO7" && bash "$SCRIPT")
assert_eq "claude/ prefix → stripped" "test-setup-script-v56UV" "$OUT"

# --- Case 8: on main → task-<timestamp> (no slug collision across runs) ---
#
# `git branch --show-current` returns "main" (non-empty), so the parameter
# expansion fallback `${slug:-...}` would NOT trigger. Explicit main/master
# check is required to prevent concurrent maintenance runs from sharing
# `.work/main` and overwriting each other's artifacts.

REPO8="$TEST_TMPDIR/repo8"
mkdir -p "$REPO8"
(
  cd "$REPO8" || exit 1
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test"
  git commit -q --allow-empty -m "init"
)
OUT=$(cd "$REPO8" && bash "$SCRIPT")
if [[ "$OUT" =~ ^task-[0-9]{8}-[0-9]{4}$ ]]; then
  pass "on main → task-YYYYMMDD-HHMM (not 'main')"
else
  fail "on main → task-YYYYMMDD-HHMM (not 'main')" "task-YYYYMMDD-HHMM" "$OUT"
fi

# --- Case 9: on master → same timestamp fallback ---

REPO9="$TEST_TMPDIR/repo9"
mkdir -p "$REPO9"
(
  cd "$REPO9" || exit 1
  git init -q -b master
  git config user.email "test@example.com"
  git config user.name "Test"
  git commit -q --allow-empty -m "init"
)
OUT=$(cd "$REPO9" && bash "$SCRIPT")
if [[ "$OUT" =~ ^task-[0-9]{8}-[0-9]{4}$ ]]; then
  pass "on master → task-YYYYMMDD-HHMM"
else
  fail "on master → task-YYYYMMDD-HHMM" "task-YYYYMMDD-HHMM" "$OUT"
fi

[[ $FAILED -eq 0 ]] || exit 1
