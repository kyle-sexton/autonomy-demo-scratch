#!/usr/bin/env bash
# shellcheck disable=SC2154
# Regression tests for tools/promote-publicapi.sh.
#
# Coverage:
#   - missing libs/dotnet → exit 1
#   - Unshipped additions promoted into Shipped (sorted, deduped)
#   - *REMOVED* lines drop matching Shipped entries
#   - Unshipped reset to header-only after promotion
#   - empty Unshipped (header-only) → idempotent skip
#
# Tests run from a per-case fake git repo so `git rev-parse --show-toplevel`
# inside the script resolves to the fixture, not the real repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/promote-publicapi.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Run script with the fake repo as CWD so git rev-parse resolves there.
run_in() {
  local repo="$1"
  (cd "$repo" && bash "$SCRIPT" 2>&1)
}

# --- Case 1: missing libs/dotnet → exit 1 ---
REPO_NO_LIBS="$TEST_TMPDIR/no-libs"
make_repo "$REPO_NO_LIBS"
OUT=$(run_in "$REPO_NO_LIBS")
RC=$?
assert_exit "missing libs/dotnet → exit 1" 1 "$RC"
assert_contains "missing libs/dotnet → diagnostic" "$OUT" "libs/dotnet not found"

# --- Case 2: additions promoted from Unshipped to Shipped ---
REPO_ADD="$TEST_TMPDIR/repo-add"
make_repo "$REPO_ADD"
LIB="$REPO_ADD/libs/dotnet/Platform.Test"
mkdir -p "$LIB"
printf '#nullable enable\nFoo.Bar\n' >"$LIB/PublicAPI.Shipped.txt"
printf '#nullable enable\nBaz.Qux\nAlpha.Beta\n' >"$LIB/PublicAPI.Unshipped.txt"

OUT=$(run_in "$REPO_ADD")
RC=$?
assert_exit "additions → exit 0" 0 "$RC"
assert_contains "additions → promote message" "$OUT" "promote:"

# Shipped should now contain Alpha.Beta + Baz.Qux + Foo.Bar (sorted) + header
mapfile -t SHIPPED <"$LIB/PublicAPI.Shipped.txt"
assert_eq "shipped[0] header" "#nullable enable" "${SHIPPED[0]}"
assert_eq "shipped[1] sorted first" "Alpha.Beta" "${SHIPPED[1]}"
assert_eq "shipped[2] sorted second" "Baz.Qux" "${SHIPPED[2]}"
assert_eq "shipped[3] sorted third" "Foo.Bar" "${SHIPPED[3]}"

# Unshipped should be header-only
UNSHIPPED_CONTENT=$(cat "$LIB/PublicAPI.Unshipped.txt")
assert_eq "unshipped reset to header" "#nullable enable" "$UNSHIPPED_CONTENT"

# --- Case 3: *REMOVED* drops matching Shipped entry ---
REPO_REM="$TEST_TMPDIR/repo-rem"
make_repo "$REPO_REM"
LIB="$REPO_REM/libs/dotnet/Platform.Test"
mkdir -p "$LIB"
printf '#nullable enable\nFoo.Bar\nFoo.Baz\n' >"$LIB/PublicAPI.Shipped.txt"
printf '#nullable enable\n*REMOVED*Foo.Bar\n' >"$LIB/PublicAPI.Unshipped.txt"

OUT=$(run_in "$REPO_REM")
RC=$?
assert_exit "removal → exit 0" 0 "$RC"

SHIPPED_AFTER=$(cat "$LIB/PublicAPI.Shipped.txt")
assert_not_contains "Foo.Bar removed from Shipped" "$SHIPPED_AFTER" "Foo.Bar"
assert_contains "Foo.Baz preserved in Shipped" "$SHIPPED_AFTER" "Foo.Baz"

# --- Case 4: empty Unshipped → skip (idempotent) ---
REPO_NOOP="$TEST_TMPDIR/repo-noop"
make_repo "$REPO_NOOP"
LIB="$REPO_NOOP/libs/dotnet/Platform.Test"
mkdir -p "$LIB"
printf '#nullable enable\nFoo.Bar\n' >"$LIB/PublicAPI.Shipped.txt"
printf '#nullable enable\n' >"$LIB/PublicAPI.Unshipped.txt"

OUT=$(run_in "$REPO_NOOP")
RC=$?
assert_exit "no-op → exit 0" 0 "$RC"
assert_contains "no-op → skip message" "$OUT" "skip:"

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
