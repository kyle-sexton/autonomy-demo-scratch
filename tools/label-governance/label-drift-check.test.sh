#!/usr/bin/env bash
# Tests for label-drift-check.sh — the runnable half of the S11 acceptance:
# fails loudly on injected drift, and (the S7/S8/S9 trap) a fetch failure is an
# ERROR, never a clean result.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

CHECK="$SCRIPT_DIR/label-drift-check.sh"
FAILED=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DECLARED="$WORK/declared.txt"
printf '%s\n' "priority: critical" "area: ci-cd" "automated" "status: ready" >"$DECLARED"

# --- usage guards ---
rc=$(
  bash "$CHECK" --declared "$DECLARED" >/dev/null 2>&1
  echo $?
)
assert_exit "missing --repo exits usage(2)" 2 "$rc"

rc=$(
  bash "$CHECK" --repo x/y --declared "$WORK/nope.txt" >/dev/null 2>&1
  echo $?
)
assert_exit "missing declared file exits usage(2)" 2 "$rc"

help_out=$(bash "$CHECK" --help 2>/dev/null)
help_rc=$?
assert_exit "--help exits 0" 0 "$help_rc"
assert_contains "--help prints usage" "$help_out" "Usage:"

# --- clean: every live label is declared ---
printf '%s\n' "priority: critical" "automated" >"$WORK/live-clean.txt"
out=$(bash "$CHECK" --repo x/y --declared "$DECLARED" --live "$WORK/live-clean.txt" 2>&1)
rc=$?
assert_exit "clean live set exits 0" 0 "$rc"
assert_contains "clean reports no undeclared" "$out" "no undeclared labels"

# --- injected drift: an undeclared label fails loudly (exit 1 + names it) ---
printf '%s\n' "priority: critical" "type:chore" "bogus-undeclared-xyz" >"$WORK/live-drift.txt"
out=$(bash "$CHECK" --repo x/y --declared "$DECLARED" --live "$WORK/live-drift.txt" 2>&1)
rc=$?
assert_exit "injected drift exits 1" 1 "$rc"
assert_contains "drift names the bogus label" "$out" "bogus-undeclared-xyz"
assert_contains "drift names the retired type: label" "$out" "type:chore"

# --- substring safety: 'area: ci' must NOT be absorbed by declared 'area: ci-cd' ---
printf '%s\n' "area: ci" >"$WORK/live-sub.txt"
rc=$(
  bash "$CHECK" --repo x/y --declared "$DECLARED" --live "$WORK/live-sub.txt" >/dev/null 2>&1
  echo $?
)
assert_exit "substring of a declared name is still drift" 1 "$rc"

# --- fail-closed: empty declared set is an ERROR, not "everything drifts" ---
: >"$WORK/empty.txt"
rc=$(
  bash "$CHECK" --repo x/y --declared "$WORK/empty.txt" --live "$WORK/live-clean.txt" >/dev/null 2>&1
  echo $?
)
assert_exit "empty declared set fails closed (3)" 3 "$rc"

# --- fail-closed: a gh fetch failure is a DATA ERROR (3), never clean (0) ---
STUB="$WORK/bin"
mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "gh: HTTP 403" >&2\nexit 1\n' >"$STUB/gh"
chmod +x "$STUB/gh"
out=$(PATH="$STUB:$PATH" bash "$CHECK" --repo x/y --declared "$DECLARED" 2>&1)
rc=$?
assert_exit "gh non-zero exit fails closed (3), never 0" 3 "$rc"
assert_contains "gh failure explicitly refuses 'no drift'" "$out" "NOT as 'no drift'"

# --- a genuinely empty-but-OK fetch (exit 0, no labels) is clean, not an error ---
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/gh"
rc=$(
  PATH="$STUB:$PATH" bash "$CHECK" --repo x/y --declared "$DECLARED" >/dev/null 2>&1
  echo $?
)
assert_exit "empty live set with gh exit 0 is clean (0)" 0 "$rc"

# --- allowlist: undeclared labels all matching the allowlist track (exit 4), don't block ---
printf '%s\n' "ecosystem: *" "recurring" >"$WORK/allowlist.txt"
printf '%s\n' "priority: critical" "ecosystem: dotnet" "recurring" >"$WORK/live-tracked.txt"
out=$(bash "$CHECK" --repo x/y --declared "$DECLARED" --live "$WORK/live-tracked.txt" --allowlist "$WORK/allowlist.txt" 2>&1)
rc=$?
assert_exit "all-allowlisted drift exits 4 (tracked, not blocking)" 4 "$rc"
assert_contains "tracked run still names the undeclared labels" "$out" "ecosystem: dotnet"
assert_contains "tracked run says allowlist absorbed them" "$out" "matched the allowlist"

# --- allowlist: a mix of allowlisted and non-allowlisted undeclared labels still blocks (exit 1) ---
printf '%s\n' "priority: critical" "ecosystem: dotnet" "bogus-undeclared-xyz" >"$WORK/live-mixed.txt"
out=$(bash "$CHECK" --repo x/y --declared "$DECLARED" --live "$WORK/live-mixed.txt" --allowlist "$WORK/allowlist.txt" 2>&1)
rc=$?
assert_exit "mixed allowlisted+blocking drift still exits 1" 1 "$rc"
assert_contains "mixed run names the blocking label" "$out" "bogus-undeclared-xyz"
assert_contains "mixed run marks it BLOCKING" "$out" "BLOCKING"

# --- allowlist: a missing --allowlist file is a usage error ---
rc=$(
  bash "$CHECK" --repo x/y --declared "$DECLARED" --allowlist "$WORK/nope-allowlist.txt" >/dev/null 2>&1
  echo $?
)
assert_exit "missing --allowlist file exits usage(2)" 2 "$rc"

# --- no --allowlist given: behavior is unchanged from before this flag existed ---
out=$(bash "$CHECK" --repo x/y --declared "$DECLARED" --live "$WORK/live-drift.txt" 2>&1)
rc=$?
assert_exit "no --allowlist: any drift still exits 1 (backward compatible)" 1 "$rc"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: label-drift-check.sh tests passed"
