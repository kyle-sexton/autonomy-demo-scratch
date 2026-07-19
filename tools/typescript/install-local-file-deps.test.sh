#!/usr/bin/env bash
# Regression tests for tools/typescript/install-local-file-deps.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel | tr -d '\r')"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

SCRIPT="$SCRIPT_DIR/install-local-file-deps.sh"

# Argument errors.
out=$(bash "$SCRIPT" 2>&1) && rc=0 || rc=$?
assert_exit "no-arg exits 2" 2 "$rc"
assert_contains "no-arg prints usage" "$out" "usage:"

out=$(bash "$SCRIPT" "$TEST_TMPDIR/missing" 2>&1) && rc=0 || rc=$?
assert_exit "missing dir exits 1" 1 "$rc"

# Directory with package.json but no file: deps -> no-op, exit 0, no install.
pkg_none="$TEST_TMPDIR/none"
mkdir -p "$pkg_none"
printf '%s\n' '{"name":"none","dependencies":{"left-pad":"^1.0.0"}}' >"$pkg_none/package.json"
out=$(bash "$SCRIPT" "$pkg_none" 2>&1) && rc=0 || rc=$?
assert_exit "no file: deps exits 0" 0 "$rc"
assert_silent "no file: deps installs nothing" "$out"

# Directory with a file: dep whose target lacks package.json -> exit 1.
pkg_bad="$TEST_TMPDIR/bad"
mkdir -p "$pkg_bad" "$TEST_TMPDIR/linktarget-empty"
printf '%s\n' '{"name":"bad","dependencies":{"dep":"file:../linktarget-empty"}}' >"$pkg_bad/package.json"
out=$(bash "$SCRIPT" "$pkg_bad" 2>&1) && rc=0 || rc=$?
assert_exit "file: dep without package.json exits 1" 1 "$rc"

[[ $FAILED -eq 0 ]] || exit 1
