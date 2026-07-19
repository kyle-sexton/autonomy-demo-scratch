#!/usr/bin/env bash
# Tests for list-md-targets.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

LIST="$SCRIPT_DIR/list-md-targets.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILED=0

assert_exit "--help exits 0" 0 "$(
  bash "$LIST" --help >/dev/null 2>&1
  echo $?
)"

git init "$TEST_TMPDIR/repo" >/dev/null 2>&1
git -C "$TEST_TMPDIR/repo" config user.email "t@example.com"
git -C "$TEST_TMPDIR/repo" config user.name "Test"
printf '# a\n' >"$TEST_TMPDIR/repo/a.md"
printf '# b\n' >"$TEST_TMPDIR/repo/b.md"
git -C "$TEST_TMPDIR/repo" add a.md
git -C "$TEST_TMPDIR/repo" commit -m "init" >/dev/null
printf '# edit\n' >>"$TEST_TMPDIR/repo/a.md"
printf '# new\n' >"$TEST_TMPDIR/repo/z-new.md"

out="$(GIT_DIR="$TEST_TMPDIR/repo/.git" GIT_WORK_TREE="$TEST_TMPDIR/repo" bash -c "cd '$TEST_TMPDIR/repo' && bash '$LIST'")"
assert_contains "count line" "$out" "Markdown target count:"
assert_contains "modified md" "$out" "Markdown target: a.md"
assert_contains "untracked md" "$out" "Markdown target: z-new.md"

paths_file="$TEST_TMPDIR/paths.txt"
printf 'docs/foo.md\nb.md\n' >"$paths_file"
file_out="$(bash "$LIST" --paths-file "$paths_file")"
assert_contains "paths-file count" "$file_out" "Markdown target count: 2"
assert_contains "paths-file entry" "$file_out" "Markdown target: docs/foo.md"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: list-md-targets.sh tests passed"
