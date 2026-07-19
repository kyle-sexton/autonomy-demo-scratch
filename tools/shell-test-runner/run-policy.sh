# Policy constants for tools/shell-test-runner — sourced by run.sh, not executed directly.
# shellcheck disable=SC2034  # constants consumed when sourced by run.sh
#
# Must-rerun-all triggers for --changed-since: if any of these paths appears in the
# diff, fall back to the full TESTS array. Cross-cutting infrastructure (runner,
# shared lib, hook utilities, lefthook config) changes the contract every test runs
# against.
#
# The trailing three are shared libs consumed by PRODUCTION scripts
# (editorconfig-check.sh, start-github-watcher.sh), not by the
# *.test.sh files. The dispatch text-grep keys on a changed file's basename
# appearing in a test body, but each lib's basename appears only in its own
# sibling test — so a lib edit would re-run that one test and miss every
# consumer's test. Force the full suite (same rationale as
# hardcoded-path-patterns.sh above). Literal paths, NOT globs: the match below
# quotes the RHS (`[[ "$f" == "$trigger" ]]`), so a glob would never match.
RERUN_ALL_TRIGGERS=(
  "tools/run-shell-tests.sh"
  "tools/shell-test-runner/run.sh"
  "tools/shell-test-runner/test-helpers.sh"
  "tests/shell/lib.sh"
  "tools/shared/path-detection/hardcoded-path-patterns.sh"
  ".claude/hooks/hook-utils.sh"
  "lefthook.yml"
  "tools/shared/eol/normalize-eol.sh"
  "tools/shared/process-management/pid-file-read.sh"
  "tools/shared/process-management/pid-graceful-stop.sh"
  "tools/worktree/create-worktree.sh"
  "tools/worktree/setup-worktree.sh"
  "tools/worktree/enforce-boundary.sh"
  "tools/worktree/worktree.sh"
  "tools/worktree/setup-cursor-worktree.sh"
)

# Kill-switch defaults (override via env at invocation):
#   BASH_TEST_GIT_DISCOVERY_ENABLED=true
#   BASH_TEST_SELECTIVE_DISPATCH_ENABLED=true
#   BASH_TEST_SCHEDULER_LONGEST_FIRST_ENABLED=true
#   BASH_TEST_RESULTS_SWEEP_ENABLED=true
#   BASH_TEST_PER_TEST_TIMEOUT_ENABLED=false
#   HOOK_OBSERVABILITY_LOG_ENABLED=false
#   HOOK_SHELL_TEST_TIMING_ENABLED=false
#   BASH_TEST_WALLTIME_HARD_ENABLED=false
#   BASH_TEST_FULLSUITE_HINT_ENABLED=true

# Per-test timeout defaults (opt-in backstop; see run-worker.sh).
BASH_TEST_PER_TEST_TIMEOUT_SECS_DEFAULT=120
BASH_TEST_PER_TEST_TIMEOUT_KILL_AFTER_SECS_DEFAULT=10

# Walltime budget defaults (per .claude/rules/bash/testing.md "Walltime budget").
BASH_TEST_WALLTIME_SOFT_MS_DEFAULT=30000
BASH_TEST_WALLTIME_HARD_MS_DEFAULT=50000

# Longest-first scheduler fallback when baseline entry missing (ms).
BASH_TEST_SCHEDULER_DEFAULT_PRIORITY_MS=15000

# RESULTS_DIR self-sweep: reclaim stale run-shell-tests.* dirs older than this (minutes).
BASH_TEST_RESULTS_SWEEP_AGE_MINUTES=240
