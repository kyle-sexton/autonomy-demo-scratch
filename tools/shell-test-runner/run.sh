#!/usr/bin/env bash
# Thin pipeline orchestrator for the shell test runner.
# Usage: bash tools/run-shell-tests.sh [<root-dir>] [--files <p>...] [--changed-since <ref>]
# Exit: 0 if all tests pass (or none found), 1 if any fail.

set -uo pipefail

if ((BASH_VERSINFO[0] < 5)); then
  printf 'run-shell-tests: bash 5.0+ required (found %s)\n' "$BASH_VERSION" >&2
  printf '  macOS: brew install bash\n' >&2
  exit 2
fi

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RUNNER_DIR/../.." && pwd)"

# shellcheck source=run-policy.sh
source "$RUNNER_DIR/run-policy.sh"
# shellcheck source=discover.sh
source "$RUNNER_DIR/discover.sh"
# shellcheck source=dispatch-selective.sh
source "$RUNNER_DIR/dispatch-selective.sh"
# shellcheck source=schedule.sh
source "$RUNNER_DIR/schedule.sh"
# shellcheck source=run-worker.sh
source "$RUNNER_DIR/run-worker.sh"
# shellcheck source=summarize.sh
source "$RUNNER_DIR/summarize.sh"

parse_runner_args "$@"
full_suite_advisory
export TEST_REPO_ROOT="$ROOT_DIR"
configure_jobs
shopt -s globstar nullglob dotglob

discover_tests
apply_selective_dispatch

if [[ ${#TESTS[@]} -eq 0 ]]; then
  printf 'No *.test.sh files found.\n' >&2
  exit 0
fi

sort_tests_longest_first
run_tests_parallel
summarize_and_exit
