#!/usr/bin/env bash
# Regression tests for full_suite_advisory — the Windows/Git Bash full-suite hint
# in run.sh (defined in dispatch-selective.sh). Verifies it fires only for a bare
# full-suite run on Windows outside CI, and stays silent in every other case.
# Platform is faked via _runner_is_windows_shell so the Windows branch is testable
# on a Linux CI runner.
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RUNNER_DIR/test-helpers.sh"
# shellcheck source=dispatch-selective.sh
source "$RUNNER_DIR/dispatch-selective.sh"

NEEDLE="--changed-since origin/main"

# Reset to the "hint should fire" baseline before each case.
reset_baseline() {
  _runner_is_windows_shell() { return 0; }      # fake Windows/Git Bash
  _runner_stderr_is_interactive() { return 0; } # fake interactive stderr
  SELECTIVE_FILES=()
  CHANGED_SINCE_REF=""
  CI=""
  BASH_TEST_FULLSUITE_HINT_ENABLED=true
  BASH_TEST_SELECTIVE_DISPATCH_ENABLED=true
}

# Case 1: Windows + bare + not CI + enabled -> hint fires.
reset_baseline
out=$(full_suite_advisory 2>&1)
assert_contains "windows bare full-suite -> hint fires" "$out" "$NEEDLE"

# Case 2: --files set -> silent.
reset_baseline
SELECTIVE_FILES=("foo.test.sh")
out=$(full_suite_advisory 2>&1)
assert_silent "--files -> silent" "$out"

# Case 3: --changed-since set -> silent.
reset_baseline
CHANGED_SINCE_REF="origin/main"
out=$(full_suite_advisory 2>&1)
assert_silent "--changed-since -> silent" "$out"

# Case 4: CI set -> silent (CI runs the full suite as the authoritative gate).
reset_baseline
CI="true"
out=$(full_suite_advisory 2>&1)
assert_silent "CI -> silent" "$out"

# Case 5: opt-out env -> silent.
reset_baseline
BASH_TEST_FULLSUITE_HINT_ENABLED=false
out=$(full_suite_advisory 2>&1)
assert_silent "opt-out env -> silent" "$out"

# Case 6: selective dispatch disabled -> silent (suggesting --changed-since is moot).
reset_baseline
BASH_TEST_SELECTIVE_DISPATCH_ENABLED=false
out=$(full_suite_advisory 2>&1)
assert_silent "selective dispatch disabled -> silent" "$out"

# Case 7: non-Windows shell -> silent.
reset_baseline
_runner_is_windows_shell() { return 1; } # fake Linux/macOS
out=$(full_suite_advisory 2>&1)
assert_silent "non-windows -> silent" "$out"

# Case 8: non-interactive stderr (captured / piped / file-redirected) -> silent.
# Covers the pre-push walltime lane, CI, and the test suite — every automated caller
# redirects the runner's stderr, so the human-facing hint never fires there.
reset_baseline
_runner_stderr_is_interactive() { return 1; } # fake captured/piped stderr
out=$(full_suite_advisory 2>&1)
assert_silent "non-interactive stderr -> silent" "$out"

report
