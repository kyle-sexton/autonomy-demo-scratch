#!/usr/bin/env bash
# Regression tests for launcher.js repo dispatch (worktree-root resolution).
#
# The contract:
#   1. Usage error if relDir or command is missing
#   2. Resolves cwd to the MAIN repo's <relDir>, even when invoked from
#      inside a linked git worktree (--git-common-dir)
#   3. Friendly error when invoked outside any git repository
#   4. Exit code propagated from spawned child (any code)
#   5. SIGINT/SIGTERM forwarded to child; launcher exits cleanly
#
# Black-box subprocess tests — spawn the launcher, observe exit + stderr.
# Signal-forwarding tests are Linux-only — Windows lacks POSIX signals
# (Node only emulates termination), so the assertions are skipped there.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/launcher.js"
REL_DIR="mcp-servers/ws-test/subdir"
TEST_TMPDIR="$(mktemp -d)"

CHILD_PID=""
cleanup() {
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

FIXTURE_REPO="$TEST_TMPDIR/repo"
git init -q "$FIXTURE_REPO"
mkdir -p "$FIXTURE_REPO/$REL_DIR"
printf 'MAIN' >"$FIXTURE_REPO/$REL_DIR/marker.txt"
git -C "$FIXTURE_REPO" add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
  git -C "$FIXTURE_REPO" commit -q -m init
git -C "$FIXTURE_REPO" branch -M main 2>/dev/null || true

WORKTREE="$TEST_TMPDIR/worktree"
git -C "$FIXTURE_REPO" worktree add -q -b feat/test "$WORKTREE" main
printf 'WORKTREE' >"$WORKTREE/$REL_DIR/marker.txt"

NONGIT_DIR="$TEST_TMPDIR/nongit"
mkdir -p "$NONGIT_DIR"

READ_MARKER='process.stdout.write(require("fs").readFileSync("marker.txt","utf8"))'

LONG_CHILD_SCRIPT="$TEST_TMPDIR/long-child.js"
cat >"$LONG_CHILD_SCRIPT" <<'JS'
const fs = require("fs");
fs.writeFileSync(process.argv[2], String(process.pid));
setInterval(() => {}, 60000);
JS

run_capture() {
  local cwd="$1"
  shift
  local out_file="$TEST_TMPDIR/run-stdout.$$"
  local err_file="$TEST_TMPDIR/run-stderr.$$"
  (cd "$cwd" && MCP_LAUNCHER_FNM_ACTIVE=1 node "$SCRIPT" "$@") >"$out_file" 2>"$err_file"
  LAST_EXIT=$?
  LAST_STDOUT=$(<"$out_file")
  LAST_STDERR=$(<"$err_file")
  rm -f "$out_file" "$err_file"
}

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

fail_msg() {
  CASE_NUM=$((CASE_NUM + 1))
  printf 'FAIL: [%d] %s\n' "$CASE_NUM" "$1" >&2
  FAILED=$((FAILED + 1))
}

run_capture "$FIXTURE_REPO"
if [[ "$LAST_EXIT" -ne 0 ]] && [[ "$LAST_STDERR" == *"missing args"* ]]; then
  pass "T1: no args → non-zero exit + missing-args on stderr"
else
  fail_msg "T1: expected non-zero exit + missing args; got exit=$LAST_EXIT stderr=$(printf '%s' "$LAST_STDERR" | head -c 200)"
fi

run_capture "$FIXTURE_REPO" "$REL_DIR"
if [[ "$LAST_EXIT" -ne 0 ]] && [[ "$LAST_STDERR" == *"Usage:"* ]]; then
  pass "T2: relDir only → non-zero exit + Usage on stderr"
else
  fail_msg "T2: expected non-zero exit + Usage; got exit=$LAST_EXIT stderr=$(printf '%s' "$LAST_STDERR" | head -c 200)"
fi

run_capture "$FIXTURE_REPO" "$REL_DIR" node -e "$READ_MARKER"
if [[ "$LAST_EXIT" -eq 0 ]] && [[ "$LAST_STDOUT" == "MAIN" ]]; then
  pass "T3: from main repo, child reads MAIN marker"
else
  fail_msg "T3: expected exit 0 + stdout 'MAIN'; got exit=$LAST_EXIT stdout=$(printf '%s' "$LAST_STDOUT" | head -c 200)"
fi

run_capture "$WORKTREE" "$REL_DIR" node -e "$READ_MARKER"
if [[ "$LAST_EXIT" -eq 0 ]] && [[ "$LAST_STDOUT" == "WORKTREE" ]]; then
  pass "T4: from linked worktree, child reads WORKTREE marker (isolation — resolves to own root)"
else
  fail_msg "T4: expected exit 0 + stdout 'WORKTREE'; got exit=$LAST_EXIT stdout=$(printf '%s' "$LAST_STDOUT" | head -c 200)"
fi

run_capture "$FIXTURE_REPO" "mcp-servers/../outside" node -e "$READ_MARKER"
if [[ "$LAST_EXIT" -ne 0 ]] && [[ "$LAST_STDERR" == *"repo path"* ]]; then
  pass "T5b: .. in relDir → rejected before spawn"
else
  fail_msg "T5b: expected repo path rejection; got exit=$LAST_EXIT stderr=$(printf '%s' "$LAST_STDERR" | head -c 200)"
fi

run_capture "$NONGIT_DIR" "$REL_DIR" node -e "$READ_MARKER"
if [[ "$LAST_EXIT" -ne 0 ]] && [[ "$LAST_STDERR" == *"not inside a git repository"* ]]; then
  pass "T6: non-git CWD → friendly error on stderr"
else
  fail_msg "T6: expected 'not inside a git repository' on stderr; got exit=$LAST_EXIT stderr=$(printf '%s' "$LAST_STDERR" | head -c 200)"
fi

run_capture "$FIXTURE_REPO" "$REL_DIR" node -e 'process.exit(7)'
assert_exit "T7: child exit 7 → launcher exit 7" 7 "$LAST_EXIT"

run_signal_test() {
  local label="$1"
  local sig="$2"
  local expected_exit="$3"

  local pid_file="$TEST_TMPDIR/child-${sig}.pid"
  rm -f "$pid_file"

  (cd "$FIXTURE_REPO" && MCP_LAUNCHER_FNM_ACTIVE=1 node "$SCRIPT" "$REL_DIR" node "$LONG_CHILD_SCRIPT" "$pid_file") &
  local wrapper_pid=$!

  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [[ -s "$pid_file" ]] && break
    sleep 0.2
  done
  if [[ ! -s "$pid_file" ]]; then
    kill -KILL "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
    fail_msg "$label: child never wrote its PID (setup failure)"
    return
  fi
  CHILD_PID=$(<"$pid_file")

  kill "-$sig" "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null
  local wrapper_exit=$?

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$CHILD_PID" 2>/dev/null || break
    sleep 0.1
  done

  local child_alive=0
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    child_alive=1
    kill -KILL "$CHILD_PID" 2>/dev/null || true
  fi
  CHILD_PID=""

  if [[ "$child_alive" -eq 0 ]] && [[ "$wrapper_exit" -eq "$expected_exit" ]]; then
    pass "$label: $sig forwarded; launcher exit $wrapper_exit, child terminated"
  else
    fail_msg "$label: expected exit $expected_exit + child terminated; got wrapper_exit=$wrapper_exit child_alive=$child_alive"
  fi
}

case "$OSTYPE" in
  msys* | cygwin* | win32)
    CASE_NUM=$((CASE_NUM + 1))
    printf 'SKIP: [%d] T8/T9: signal forwarding (Windows lacks POSIX signals)\n' "$CASE_NUM"
    ;;
  *)
    run_signal_test "T8" INT 130
    run_signal_test "T9" TERM 143
    ;;
esac

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d test(s) passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d of %d test(s) failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
