#!/usr/bin/env bash
# Worktree-safety shard for run-skill-comparison.sh: --keep-worktrees
# inspection (arm isolation + live-tree snapshot fidelity) and the startup
# stale-registration reconciler. Helpers/sibling shards documented in
# run-skill-comparison-test-helpers.sh.
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILED=0
CASE_NUM=0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-skill-comparison-test-helpers.sh"

PROMPT_FILE="$TEST_TMPDIR/prompt.txt"
make_prompt "$PROMPT_FILE"

# --- Case: arm B carries the patch; snapshot captures uncommitted live tree ---

F2="$TEST_TMPDIR/f2"
make_fixture "$F2"
PATCH2="$TEST_TMPDIR/relax2.patch"
make_patch "$F2" "$PATCH2"
printf 'uncommitted live-only file\n' >"$F2/live-only.txt"

OUT=$(run_driver "$F2" "$TEST_TMPDIR/wt2" \
  --prompt-file "$PROMPT_FILE" --patch "$PATCH2" --model fable \
  --trials 1 --label keep --out "$TEST_TMPDIR/out2" --dry-run --keep-worktrees)
RC=$?
assert_exit "keep-worktrees dry-run exits 0" 0 "$RC"
KEPT_PREFIX="$(grep -o 'kept worktrees under: .*' <<<"$OUT" | sed 's/^kept worktrees under: //' | tr -d '\r')"
if [[ -n "$KEPT_PREFIX" && -d "$KEPT_PREFIX" ]]; then
  pass "kept worktree prefix reported and present"
else
  fail "kept worktree prefix reported and present" "existing dir" "${KEPT_PREFIX:-none}"
fi
assert_eq "arm A body is as-committed" "original body line" "$(cat "$KEPT_PREFIX/arm-a/skill.md")"
assert_eq "arm B body carries the relaxation patch" "relaxed body line" "$(cat "$KEPT_PREFIX/arm-b/skill.md")"
assert_file_exists "snapshot captured uncommitted live-tree file" "$KEPT_PREFIX/arm-a/live-only.txt"
ARM_B_PORCELAIN="$(git -C "$KEPT_PREFIX/arm-b" status --porcelain)"
assert_contains "arm B patch is uncommitted (never lands on a branch)" "$ARM_B_PORCELAIN" "skill.md"

# --- Case: startup reconciler removes stale own-prefix registrations only ---

F3="$TEST_TMPDIR/f3"
make_fixture "$F3"
PATCH3="$TEST_TMPDIR/relax3.patch"
make_patch "$F3" "$PATCH3"
mkdir -p "$TEST_TMPDIR/wt3"
git -C "$F3" worktree add --detach --quiet "$TEST_TMPDIR/wt3/skill-comparison.stale" HEAD
rm -rf "$TEST_TMPDIR/wt3/skill-comparison.stale"

OUT=$(run_driver "$F3" "$TEST_TMPDIR/wt3" \
  --prompt-file "$PROMPT_FILE" --patch "$PATCH3" --model fable \
  --trials 1 --label recon --out "$TEST_TMPDIR/out3" --dry-run)
RC=$?
assert_exit "reconciler run exits 0" 0 "$RC"
assert_contains "reconciler announced the stale removal" "$OUT" "removing stale worktree registration"
WT_LIST="$(git -C "$F3" worktree list)"
assert_not_contains "stale registration gone" "$WT_LIST" "skill-comparison.stale"
assert_not_contains "fresh run's own worktrees torn down too" "$WT_LIST" "skill-comparison"

assert_real_hub_unchanged
report
