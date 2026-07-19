#!/usr/bin/env bash
# Tests for tools/worktree/lib/copy-worktreeinclude.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)/tests/shell/lib.sh"
source "$SCRIPT_DIR/copy-worktreeinclude.sh"

FAILED=0
CASE_NUM=0

base="$(mktemp -d)"
mkdir -p "$base/main/.claude" "$base/worktree"
printf '%s\n' '.claude/settings.local.json' >"$base/main/.worktreeinclude"
printf '{"env":{"GH_TOKEN":"x"}}' >"$base/main/.claude/settings.local.json"

worktree_lib_copy_worktreeinclude "$base/main" "$base/worktree" "test" >/dev/null 2>&1
assert_file_exists "copied settings.local.json" "$base/worktree/.claude/settings.local.json"
assert_eq "content matches" \
  "$(cat "$base/main/.claude/settings.local.json")" \
  "$(cat "$base/worktree/.claude/settings.local.json")"

rc=0
worktree_lib_copy_worktreeinclude "" "$base/worktree" >/dev/null 2>&1 || rc=$?
assert_exit "empty source returns 0" 0 "$rc"

rm -rf "$base"
[[ $FAILED -eq 0 ]] || exit 1
