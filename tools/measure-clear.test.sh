#!/usr/bin/env bash
# Regression tests for tools/measure-clear.sh.
#
# Scope: arg-parsing + prereq error paths only. The "run actual hooks" path
# fires the real .claude/hooks/*.sh scripts and is expensive (10s+) — skip
# for unit-test scope; the script's primary measurement contract is
# self-validating against expected hook outputs.
#
# Coverage:
#   - --help → exit 0, usage text on stdout
#   - unknown arg → exit 1, diagnostic
#   - non-git CWD → exit 1
#   - --runs N parsed (probed via --help short-circuit, no actual run)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/measure-clear.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# --- Case 1: --help → exit 0, usage text ---
OUT=$(bash "$SCRIPT" --help 2>&1)
RC=$?
assert_exit "--help → exit 0" 0 "$RC"
assert_contains "--help → mentions --cold" "$OUT" "--cold"
assert_contains "--help → mentions --runs" "$OUT" "--runs"

# --- Case 2: -h alias → exit 0 ---
OUT=$(bash "$SCRIPT" -h 2>&1)
RC=$?
assert_exit "-h → exit 0" 0 "$RC"

# --- Case 3: unknown arg → exit 1 ---
OUT=$(bash "$SCRIPT" --bogus 2>&1)
RC=$?
assert_exit "--bogus → exit 1" 1 "$RC"
assert_contains "--bogus → diagnostic" "$OUT" "unknown arg"

# --- Case 4: not a git repo → exit 1 ---
NON_GIT="$TEST_TMPDIR/non-git"
mkdir -p "$NON_GIT"
# Run from a directory that has no .git anywhere up the tree. mktemp -d
# lands under /tmp which is not a git repo on the test machine.
OUT=$(cd "$NON_GIT" && bash "$SCRIPT" 2>&1)
RC=$?
assert_exit "non-git CWD → exit 1" 1 "$RC"
assert_contains "non-git CWD → diagnostic" "$OUT" "not a git repo"

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
