#!/usr/bin/env bash
# Tests for list-managed-repos.sh — enumerate label-managed repos from a
# github-iac program, honoring the ManagedLabels default (true) and opt-out.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

LIST="$SCRIPT_DIR/list-managed-repos.sh"
FAILED=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

IAC="$WORK/iac"
mkdir -p "$IAC"
cat >"$IAC/GovernedRepositories.cs" <<'CS'
    new("alpha", a => { a.Visibility = "public"; }),
    new("beta", a => { a.Visibility = "private"; }, ManagedLabels: false),
    new("gamma", a => { a.Visibility = "private"; },
    ExtraLabels: [ ("x", "111111", "d") ]),
    new("delta-archive", a => { a.Visibility = "private"; }, ManagedLabels: false, Archived: true),
CS

out=$(bash "$LIST" --iac-dir "$IAC" --owner acme)
rc=$?
assert_exit "listing exits 0" 0 "$rc"
assert_contains "managed repo (default true) included" "$out" "acme/alpha"
assert_contains "managed repo with ExtraLabels included" "$out" "acme/gamma"
assert_not_contains "ManagedLabels:false opt-out excluded" "$out" "acme/beta"
assert_not_contains "archived opt-out excluded" "$out" "acme/delta-archive"

# --- usage guards ---
rc=$(
  bash "$LIST" --iac-dir "$IAC" >/dev/null 2>&1
  echo $?
)
assert_exit "missing --owner exits usage(2)" 2 "$rc"

# --- fail-closed: no specs ---
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
printf '// no specs here\n' >"$EMPTY/GovernedRepositories.cs"
rc=$(
  bash "$LIST" --iac-dir "$EMPTY" --owner acme >/dev/null 2>&1
  echo $?
)
assert_exit "no specs fails closed (3)" 3 "$rc"

help_out=$(bash "$LIST" --help 2>/dev/null)
help_rc=$?
assert_exit "--help exits 0" 0 "$help_rc"
assert_contains "--help prints usage" "$help_out" "Usage:"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: list-managed-repos.sh tests passed"
