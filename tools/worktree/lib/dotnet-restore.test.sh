#!/usr/bin/env bash
# Tests for tools/worktree/lib/dotnet-restore.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"
# shellcheck source=dotnet-restore.sh
source "$SCRIPT_DIR/dotnet-restore.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

WT="$TEST_TMPDIR/wt"
mkdir -p "$WT"

rc=0
(
  cd "$WT" || exit 1
  worktree_lib_dotnet_restore skip
) || rc=$?
assert_exit "skip mode returns 0" 0 "$rc"

rc=0
(
  cd "$WT" || exit 1
  worktree_lib_dotnet_restore if-stale
) || rc=$?
assert_exit "no slnx → if-stale returns 0" 0 "$rc"

STALE="$TEST_TMPDIR/stale"
mkdir -p "$STALE/app/obj"
printf 'fake' >"$STALE/App.slnx"
printf '{}' >"$STALE/app/obj/project.assets.json"
touch -t 202001010000 "$STALE/app/obj/project.assets.json"
printf '<Project Sdk="Microsoft.NET.Sdk"></Project>' >"$STALE/app/App.csproj"
touch -t 202101010000 "$STALE/app/App.csproj"

cd "$STALE" || exit 1
if worktree_lib_dotnet_restore_needed; then
  pass "stale tree needs restore"
else
  fail "stale tree needs restore" "needed" "not needed"
fi

FRESH="$TEST_TMPDIR/fresh"
mkdir -p "$FRESH/app/obj"
printf 'fake' >"$FRESH/App.slnx"
printf '{}' >"$FRESH/app/obj/project.assets.json"
touch -t 202501010000 "$FRESH/app/obj/project.assets.json"
printf '<Project Sdk="Microsoft.NET.Sdk"></Project>' >"$FRESH/app/App.csproj"
touch -t 202401010000 "$FRESH/app/App.csproj"

cd "$FRESH" || exit 1
if worktree_lib_dotnet_restore_needed; then
  fail "fresh assets skip restore" "skip" "needed"
else
  pass "fresh assets skip restore"
fi

if command -v dotnet >/dev/null 2>&1; then
  rc=0
  worktree_lib_dotnet_restore if-stale || rc=$?
  assert_exit "if-stale on fresh tree returns 0" 0 "$rc"
else
  skip_case "dotnet not installed — skipping if-stale integration"
fi

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
