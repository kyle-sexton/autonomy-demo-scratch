#!/usr/bin/env bash
# Contract + dry-run-cycle shard for run-skill-comparison.sh. Sibling shards:
# run-skill-comparison-worktree-safety.test.sh (keep-worktrees, stale
# reconciler) and run-skill-comparison-failure-paths.test.sh (interrupt
# cleanup, cost covariate). Shared fixtures/assertions live in
# run-skill-comparison-test-helpers.sh.
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILED=0
CASE_NUM=0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-skill-comparison-test-helpers.sh"

PROMPT_FILE="$TEST_TMPDIR/prompt.txt"
make_prompt "$PROMPT_FILE"

# --- Case: --help exits 0 with non-empty stdout ---

OUT=$(bash "$DRIVER" --help)
RC=$?
assert_exit "--help exits 0" 0 "$RC"
assert_contains "--help documents the contract" "$OUT" "--prompt-file"
assert_contains "--help documents CLAUDE_BIN" "$OUT" "CLAUDE_BIN"

# --- Case: missing required args is a usage error (exit 2) ---

OUT=$(bash "$DRIVER" --model fable 2>&1)
RC=$?
assert_exit "missing args exit 2" 2 "$RC"
assert_contains "missing args named" "$OUT" "missing required arguments"

# --- Case: dry-run full cycle (snapshot, arms, runs, scrub, teardown) ---

F1="$TEST_TMPDIR/f1"
make_fixture "$F1"
PATCH1="$TEST_TMPDIR/relax1.patch"
make_patch "$F1" "$PATCH1"
COMMON_DIR="$(git -C "$F1" rev-parse --path-format=absolute --git-common-dir)"
# git emits native (Windows, long-name) form on Git Bash while mktemp emits
# POSIX form — compare against both (-l avoids 8.3 short names like USERNA~1).
TEST_TMPDIR_NATIVE="$TEST_TMPDIR"
if command -v cygpath >/dev/null 2>&1; then
  TEST_TMPDIR_NATIVE="$(cygpath -lm "$TEST_TMPDIR")"
fi
case "$COMMON_DIR" in
  "$TEST_TMPDIR"* | "$TEST_TMPDIR_NATIVE"*) pass "fixture --git-common-dir is under the test tmpdir" ;;
  *) fail "fixture --git-common-dir is under the test tmpdir" "$TEST_TMPDIR/*" "$COMMON_DIR" ;;
esac
printf 'live-only uncommitted content\n' >"$F1/extra.txt"
PORCELAIN_BEFORE="$(git -C "$F1" status --porcelain)"

OUT1_DIR="$TEST_TMPDIR/out1"
OUT=$(run_driver "$F1" "$TEST_TMPDIR/wt1" \
  --prompt-file "$PROMPT_FILE" --patch "$PATCH1" --model fable \
  --trials 2 --label ftest --out "$OUT1_DIR" --dry-run)
RC=$?
assert_exit "dry-run exits 0" 0 "$RC"
assert_contains "dry-run reports batch complete" "$OUT" "batch complete: 4 OK, 0 scrub-pending, 0 failed"

RUN_DIR_COUNT="$(find "$OUT1_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' \r')"
assert_eq "2 trials x 2 arms = 4 run dirs" "4" "$RUN_DIR_COUNT"

FIRST_RUN_DIR="$(find "$OUT1_DIR" -mindepth 1 -maxdepth 1 -type d | sort | head -1)"
assert_file_exists "transcript captured" "$FIRST_RUN_DIR/transcript.jsonl"
assert_file_exists "meta captured" "$FIRST_RUN_DIR/meta.json"
assert_eq "meta status OK" "OK" "$(jq -r .status "$FIRST_RUN_DIR/meta.json")"
assert_contains "meta actual model matches requested alias" \
  "$(jq -r .model_actual "$FIRST_RUN_DIR/meta.json")" "fable"
assert_eq "meta zero cost on fable" "0" "$(jq -r .total_cost_usd "$FIRST_RUN_DIR/meta.json")"
assert_contains "meta records mcp_servers covariate" \
  "$(jq -c .mcp_servers "$FIRST_RUN_DIR/meta.json")" "stub"

assert_file_exists "results.md ledger created" "$OUT1_DIR/results.md"
ROWS="$(grep -c '| ftest |' "$OUT1_DIR/results.md" || true)"
assert_eq "ledger has 4 skeleton rows" "4" "$ROWS"

PORCELAIN_AFTER="$(git -C "$F1" status --porcelain)"
assert_eq "live tree untouched (porcelain identical)" "$PORCELAIN_BEFORE" "$PORCELAIN_AFTER"

WT_LIST="$(git -C "$F1" worktree list)"
assert_not_contains "worktrees torn down after batch" "$WT_LIST" "skill-comparison"

TRANSCRIPT_BODY="$(cat "$FIRST_RUN_DIR/transcript.jsonl")"
assert_contains "transcript scrubbed to <ARM> placeholder" "$TRANSCRIPT_BODY" "<ARM>/arm-"
assert_not_contains "transcript carries no raw worktree tmpdir" "$TRANSCRIPT_BODY" "$TEST_TMPDIR/wt1"

assert_real_hub_unchanged
report
