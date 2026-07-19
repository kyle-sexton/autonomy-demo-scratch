# Parallel xargs dispatch + per-test timeout — sourced by run.sh, not executed directly.
# shellcheck source=run-policy.sh
# shellcheck disable=SC2154  # TESTS/JOBS set by run.sh before run_tests_parallel

# A test path maps to a unique log basename by flattening '/' to '_'. Done
# inline as `${path//\//_}` (pure-bash parameter expansion — zero fork) at every
# call site; on Git Bash each avoided `printf | tr` subshell saves ~2 MSYS2
# forks, and summarize.sh replays this over every test serially. Two distinct
# paths flattening to the same name is unlikely with our naming convention.

# Self-sweep prior runs' leaked RESULTS_DIR trees (F4). A hard kill (TaskStop
# sends SIGKILL, which is untrappable) leaves $RESULTS_DIR behind because no
# trap fires. Giving it a distinguishable `run-shell-tests.*` prefix (instead of
# the bare `tmp.*` that mktemp emits) lets the next run safely reclaim ONLY this
# runner's own stale dirs — never another tool's mktemp output. Sweep dirs older
# than 4h, well past any live run's walltime, so a concurrent run is never
# touched. Kill switch: BASH_TEST_RESULTS_SWEEP_ENABLED=false.
prepare_results_dir() {
  RESULTS_PARENT="${TMPDIR:-/tmp}"
  if [[ "${BASH_TEST_RESULTS_SWEEP_ENABLED:-true}" == "true" ]]; then
    find "$RESULTS_PARENT" -maxdepth 1 -name 'run-shell-tests.*' -type d -mmin +"$BASH_TEST_RESULTS_SWEEP_AGE_MINUTES" \
      -exec rm -rf {} + 2>/dev/null || true
  fi
  RESULTS_DIR="$(mktemp -d "$RESULTS_PARENT/run-shell-tests.XXXXXXXX")"
  # Cleanup on normal exit AND on catchable interrupts (Ctrl-C / SIGTERM) so an
  # interrupted run does not leak its $RESULTS_DIR temp tree. Re-raise the signal
  # after cleanup so the exit status reflects the interrupt.
  #
  # SIGKILL (what `TaskStop` sends) is UNTRAPPABLE — orphaned xargs workers from a
  # hard kill cannot be reaped here, and MSYS2 cannot reliably signal native
  # Windows grandchildren (dotnet/git) via a process group either. The blast
  # radius of that un-trappable case is bounded by F3 (MSBUILDDISABLENODEREUSE,
  # below) preventing persistent dotnet/MSBuild nodes, and F2 (per-test timeout,
  # below) bounding each test's lifetime. The structural prevention for the hard-
  # kill case is workflow discipline: do not run the full suite in the background
  # during commit-heavy work (see .claude/rules/bash/testing.md "Selective dispatch").
  # Note: an interactive Ctrl-C is delivered by the terminal to the whole
  # foreground process group, so xargs and its workers receive SIGINT directly —
  # this trap only needs to clean up $RESULTS_DIR, not forward the signal.
  # A SIGTERM delivered to ONLY the runner PID (e.g. `kill <runner-pid>` from a
  # supervisor, NOT a terminal Ctrl-C) is a known, accepted gap: this trap
  # re-raises TERM to $$ alone, so an in-flight `xargs -P` worker tree keeps
  # draining the queue. Forwarding the signal is deliberately NOT attempted — the
  # runner is typically not a process-group leader (launched as
  # `bash run-shell-tests.sh`), so `kill -TERM -$$` would ESRCH rather than signal
  # the group, and even a correct group kill cannot reach native git/dotnet
  # grandchildren across the MSYS2 boundary (see docs/ecosystems/bash-gotchas-reference.md "TaskStop /
  # SIGKILL orphans background process trees"). The blast radius is bounded by the
  # same F2 (per-test timeout) and F3 (MSBUILDDISABLENODEREUSE) mitigations that
  # bound the un-trappable SIGKILL case.
  # shellcheck disable=SC2329  # invoked indirectly via the trap statements below
  cleanup() { rm -rf "$RESULTS_DIR"; }
  trap cleanup EXIT
  trap 'cleanup; trap - INT; kill -INT "$$"' INT
  trap 'cleanup; trap - TERM; kill -TERM "$$"' TERM
}

configure_worker_runtime() {
  # --- Build-server isolation (F3) -------------------------------------------
  # Tests that invoke `dotnet` (msbuild-introspect, nuget-pack-prep, the onboard
  # runtime checks, ...) otherwise spawn detached MSBuild worker nodes
  # (`/nodemode:1`) that survive the test AND the runner via node reuse. When the
  # runner is hard-killed (TaskStop sends SIGKILL, which is untrappable) those
  # nodes orphan, churn CPU across all cores, and accumulate temp dirs. Disabling
  # node reuse at the source means there is nothing to orphan even on a kill that
  # no trap can intercept.
  #   MSBUILDDISABLENODEREUSE=1       — "not leave MSBuild processes behind"
  #       (dotnet/msbuild documentation/wiki/MSBuild-Environment-Variables.md)
  #   DOTNET_CLI_USE_MSBUILD_SERVER=0 — defensive; MSBuild Server is off by
  #       default, but explicitly opt out in case a global/user setting enabled it
  #       (learn.microsoft.com/visualstudio/msbuild/msbuild-server).
  export MSBUILDDISABLENODEREUSE=1
  export DOTNET_CLI_USE_MSBUILD_SERVER=0

  # --- Per-test timeout (F2) — OPT-IN backstop, default OFF ------------------
  # `timeout` converts a genuinely-hung test (one that never returns) into a
  # bounded FAIL: exit 124 when SIGTERM ended it, or 137 (128+9) if it ignored
  # SIGTERM and was SIGKILL'd after the --kill-after grace.
  #
  # DEFAULT OFF (opt-in) on purpose. The observed "suite hung 30+ min" was
  # CONTENTION — leaked process trees from a SIGKILL'd run saturating all cores
  # (addressed by F1/F4 + the F6 "don't background the full suite during commit-
  # heavy work" discipline) — NOT a runaway test. Every test completes: the
  # slowest legitimate suites still take minutes standalone on Windows (MSYS2
  # fork tax), more under JOBS=8 contention. An always-on fixed cap cannot be
  # both above the slowest legit Windows test AND a useful hang backstop — at
  # 120s it false-kills the slowest fork-heavy suites and the statusline suite. So enable it
  # deliberately, with a value you choose, only when debugging a SPECIFIC
  # suspected genuine hang:
  #   BASH_TEST_PER_TEST_TIMEOUT_ENABLED=true BASH_TEST_PER_TEST_TIMEOUT_SECS=600 \
  #     bash tools/run-shell-tests.sh
  # Default-off preserves the pre-existing behavior (no per-test kill); enabling
  # is the only behavior change.
  #
  # Windows caveat: GNU `timeout` reliably kills the direct `bash "$t"` child
  # (freeing the xargs slot), but MSYS2 signal delivery does not propagate to
  # native-Windows grandchildren (dotnet/git). F3 keeps those from persisting;
  # this timeout's job is to unblock the queue.
  #
  # macOS Homebrew coreutils installs `timeout` as `gtimeout`; fall back to it.
  # When neither is present the timeout is skipped even when enabled.
  TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
  fi
  PER_TEST_TIMEOUT_ENABLED="${BASH_TEST_PER_TEST_TIMEOUT_ENABLED:-false}"
  PER_TEST_TIMEOUT_SECS="${BASH_TEST_PER_TEST_TIMEOUT_SECS:-$BASH_TEST_PER_TEST_TIMEOUT_SECS_DEFAULT}"
  PER_TEST_TIMEOUT_KILL_AFTER_SECS="${BASH_TEST_PER_TEST_TIMEOUT_KILL_AFTER_SECS:-$BASH_TEST_PER_TEST_TIMEOUT_KILL_AFTER_SECS_DEFAULT}"
  [[ $PER_TEST_TIMEOUT_SECS =~ ^[0-9]+$ ]] || PER_TEST_TIMEOUT_SECS="$BASH_TEST_PER_TEST_TIMEOUT_SECS_DEFAULT"
  [[ $PER_TEST_TIMEOUT_KILL_AFTER_SECS =~ ^[0-9]+$ ]] || PER_TEST_TIMEOUT_KILL_AFTER_SECS="$BASH_TEST_PER_TEST_TIMEOUT_KILL_AFTER_SECS_DEFAULT"
  # Exported so the xargs child shells running run_one inherit them.
  export TIMEOUT_BIN PER_TEST_TIMEOUT_ENABLED PER_TEST_TIMEOUT_SECS PER_TEST_TIMEOUT_KILL_AFTER_SECS
}

# Run a single test in a child shell. Captures merged stdout+stderr to
# <log>, exit code to <log>.rc, wall-clock duration to <log>.ms. Progress
# dot to TTY for live activity.
# Args: <results_dir> <test_path>
run_one() {
  local results="$1" t="$2" base log start end ms rc
  base="${t//\//_}"
  log="$results/$base.log"
  start=$EPOCHREALTIME
  if [[ -n "$TIMEOUT_BIN" && "$PER_TEST_TIMEOUT_ENABLED" == "true" ]]; then
    "$TIMEOUT_BIN" -k "$PER_TEST_TIMEOUT_KILL_AFTER_SECS" "$PER_TEST_TIMEOUT_SECS" bash "$t" >"$log" 2>&1
  else
    bash "$t" >"$log" 2>&1
  fi
  rc=$?
  # 124 = timeout sent SIGTERM; 137 = test ignored SIGTERM and was SIGKILL'd
  # after --kill-after. Annotate the log so the replay shows WHY a test failed
  # rather than surfacing a bare non-zero exit with no explanation.
  if [[ -n "$TIMEOUT_BIN" && "$PER_TEST_TIMEOUT_ENABLED" == "true" ]] \
    && { [[ $rc -eq 124 ]] || [[ $rc -eq 137 ]]; }; then
    printf '\nTIMEOUT: exceeded %ss per-test cap (killed; rc=%d).\n' \
      "$PER_TEST_TIMEOUT_SECS" "$rc" >>"$log"
  fi
  printf '%d\n' "$rc" >"$log.rc"
  end=$EPOCHREALTIME
  # ($end - $start) * 1000 — both have microsecond precision. awk avoids
  # floating-point arithmetic in shell. On the unlikely chance awk fails
  # (PATH stripped, /bin/sh-only sandbox), fall back to 0 — observability
  # degrades but the run completes.
  ms=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%d", (e-s)*1000}' 2>/dev/null) || ms=0
  printf '%s\n' "$ms" >"$log.ms"
  printf '.' >&2
}
export -f run_one

detect_jobs() {
  local n=""
  if command -v nproc >/dev/null 2>&1; then
    n=$(nproc 2>/dev/null) || n=""
  fi
  if [[ -z $n ]] && command -v sysctl >/dev/null 2>&1; then
    n=$(sysctl -n hw.logicalcpu 2>/dev/null) || n=""
  fi
  if [[ -z $n ]] && command -v getconf >/dev/null 2>&1; then
    n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
  fi
  [[ $n =~ ^[0-9]+$ ]] || n=4
  [[ $n -lt 1 ]] && n=1
  [[ $n -gt 8 ]] && n=8
  printf '%d\n' "$n"
}

# Default to detected CPU count, clamped to [1, 8]. Override with JOBS=N.
configure_jobs() {
  JOBS="${JOBS:-$(detect_jobs)}"
  [[ $JOBS =~ ^[0-9]+$ ]] || JOBS=1
  [[ $JOBS -lt 1 ]] && JOBS=1
}

run_tests_parallel() {
  prepare_results_dir
  configure_worker_runtime

  printf 'Discovering: %d test file(s). Running with JOBS=%d worker(s).\n' \
    "${#TESTS[@]}" "$JOBS"
  # shellcheck disable=SC2034  # consumed by summarize.sh
  START_EPOCH=$EPOCHREALTIME

  if [[ $JOBS -gt 1 ]]; then
    # xargs -P fans out the test list across $JOBS concurrent workers. -n1
    # binds one test per worker invocation. The inner shell calls run_one
    # which writes log + .rc to disk; nothing is streamed back through the
    # xargs pipe, so worker output never interleaves on the controlling
    # terminal (besides the progress dots, which are atomic single bytes).
    # `-I {}` implies `-n 1` — passing both triggers a POSIX warning. The
    # placeholder substitutes the test path; one bash -c per test fans out
    # across $JOBS concurrent workers.
    printf '%s\n' "${TESTS[@]}" \
      | xargs -P "$JOBS" -I{} bash -c 'run_one "$1" "$2"' _ "$RESULTS_DIR" {}
  else
    for t in "${TESTS[@]}"; do
      run_one "$RESULTS_DIR" "$t"
    done
  fi
  printf '\n' >&2
}
