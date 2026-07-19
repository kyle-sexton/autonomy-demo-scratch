#!/usr/bin/env bash
# Regression tests for check-host-container-env-boundary.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOK="$SCRIPT_DIR/check-host-container-env-boundary.sh"
# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

assert_exit() {
  local label="$1" expected="$2"
  shift 2
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expected" ]]; then
    printf 'FAIL: %s — expected exit %s got %s\n%s\n' "$label" "$expected" "$rc" "$out" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

build_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
  printf '%s\n' "$dir"
}

# Clean host env in subshell
run_check() {
  (
    cd "$1"
    env -u CLAUDE_PROJECT_DIR -u GIT_WORK_TREE bash "$HOOK"
  )
}

REPO="$(build_repo)"
trap 'rm -rf "$REPO"' EXIT

assert_exit "clean repo passes" 0 run_check "$REPO"

LEAK_REPO="$(build_repo)"
git -C "$LEAK_REPO" config --local core.worktree /workspace
assert_exit "core.worktree sentinel fails" 1 run_check "$LEAK_REPO"
rm -rf "$LEAK_REPO"

case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*)
    FM_REPO="$(build_repo)"
    git -C "$FM_REPO" config core.filemode true
    assert_exit "core.filemode true fails on Windows" 1 run_check "$FM_REPO"
    rm -rf "$FM_REPO"
    ;;
esac

AC_REPO="$(build_repo)"
git -C "$AC_REPO" config core.autocrlf true
assert_exit "core.autocrlf true fails" 1 run_check "$AC_REPO"
rm -rf "$AC_REPO"

SD_REPO="$(build_repo)"
git -C "$SD_REPO" config --add safe.directory '*'
assert_exit "safe.directory star fails" 1 run_check "$SD_REPO"
rm -rf "$SD_REPO"

printf 'all check-host-container-env-boundary tests passed\n'
