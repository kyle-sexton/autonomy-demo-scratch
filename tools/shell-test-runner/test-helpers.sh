#!/usr/bin/env bash
# Shared fixture + assertion helpers for the shell-test-runner/*.test.sh shards.
#
# Sourced (NOT *.test.sh-named, so run.sh ignores it) by each concern shard
# AFTER the shard sets its own TEST_TMPDIR + cleanup trap. Each shard owns its
# TEST_TMPDIR, so parallel shards under xargs -P never collide on the fixture
# dir. Run a shard directly: bash tools/shell-test-runner/<concern>.test.sh
set -uo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HELPER_DIR/../run-shell-tests.sh"

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Build a fixture *.test.sh under $TEST_TMPDIR/<name>.test.sh with the given
# body. Each fixture is its own file so the runner discovers each via globstar.
make_fixture() {
  local name="$1" body="$2"
  # shellcheck disable=SC2154  # TEST_TMPDIR is set by the sourcing shard
  printf '%s\n' "$body" >"$TEST_TMPDIR/$name.test.sh"
}

run_runner() {
  # Capture both streams; classification logic is the assertion target.
  # shellcheck disable=SC2154  # TEST_TMPDIR is set by the sourcing shard
  bash "$RUNNER" "$TEST_TMPDIR" 2>&1
}

report() {
  if [[ $FAILED -ne 0 ]]; then
    printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
    exit 1
  fi
  printf '\nAll %d cases passed.\n' "$CASE_NUM"
  exit 0
}
