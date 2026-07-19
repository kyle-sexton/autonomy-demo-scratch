#!/usr/bin/env bash
# Tests for repo-grep.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

RG="$SCRIPT_DIR/repo-grep.sh"
FAILED=0

help_code=$(
  bash "$RG" --help >/dev/null 2>&1
  echo $?
)
assert_exit "--help exits 0" 0 "$help_code"

git_out=$(bash "$RG" -F 'File roles' --max-count 1 2>/dev/null || true)
assert_contains "git engine finds AGENTS.md" "$git_out" "AGENTS.md"

# Regression: a leading-slash pattern (e.g. a slash-command literal) must still match.
# On Windows/Git Bash, MSYS rewrites "/architect" into a Windows path before git.exe sees
# it, so without the MSYS_NO_PATHCONV guard in run_git_grep the search silently matches
# nothing. No-op on Linux/macOS (this always passed there); guards the Windows regression.
slash_out=$(bash "$RG" -F '/architect' --max-count 1 2>/dev/null || true)
assert_contains "git engine matches a leading-slash pattern" "$slash_out" "/architect"

if command -v rg >/dev/null 2>&1; then
  data_files=$(cd "$REPO_ROOT" && rg --files .work/ 2>/dev/null | grep '/data/' | head -1 || true)
  if [[ -n "$data_files" ]]; then
    fail ".ignore excludes .work/**/data/ from rg --files .work/" "no files under data/" "$data_files"
  else
    pass ".ignore excludes .work/**/data/ from rg --files .work/"
  fi
fi

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: repo-grep.sh tests passed"
