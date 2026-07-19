# Results replay, walltime budget, JSONL observability — sourced by run.sh, not executed directly.
# shellcheck source=run-policy.sh
# shellcheck source=run-worker.sh
# shellcheck disable=SC2154  # TESTS/RESULTS_DIR/JOBS/START_EPOCH/END_EPOCH set by run.sh pipeline

summarize_and_exit() {
  # Replay results in deterministic order (the original sorted TESTS array).
  # Aggregate counts during the same walk.
  TOTAL=0
  PASSED=0
  PARTIAL=0
  SKIPPED=0
  FAILED=0
  FAILED_FILES=()
  SKIPPED_FILES=()
  PARTIAL_FILES=()

  for t in "${TESTS[@]}"; do
    TOTAL=$((TOTAL + 1))
    base="${t//\//_}"
    log="$RESULTS_DIR/$base.log"
    rc_file="$log.rc"

    printf '\n--- %s ---\n' "$t"
    cat "$log"
    rc=255
    [[ -r "$rc_file" ]] && rc=$(<"$rc_file")

    # One awk pass replaces two `grep -c` forks. `p+0`/`s+0` coerce to integer 0
    # when a marker is absent. Serial over every test file — the saved fork pays.
    pass=0 skip=0
    [[ -r "$log" ]] && read -r pass skip \
      <<<"$(awk '/^PASS: /{p++} /^SKIP: /{s++} END{printf "%d %d", p + 0, s + 0}' "$log" 2>/dev/null)"

    if [[ $rc -ne 0 ]]; then
      FAILED=$((FAILED + 1))
      FAILED_FILES+=("$t")
    elif [[ $pass -eq 0 && $skip -gt 0 ]]; then
      SKIPPED=$((SKIPPED + 1))
      SKIPPED_FILES+=("$t")
    elif [[ $pass -gt 0 && $skip -gt 0 ]]; then
      PARTIAL=$((PARTIAL + 1))
      PARTIAL_FILES+=("$t ($skip skip)")
    else
      PASSED=$((PASSED + 1))
    fi
  done

  # Wall-clock elapsed using bash builtin (no `date` fork on Windows hot path)
  END_EPOCH=$EPOCHREALTIME
  ELAPSED=$(awk -v s="$START_EPOCH" -v e="$END_EPOCH" 'BEGIN{printf "%.1f", e-s}')

  printf '\n=== Summary ===\n'
  printf '%d test file(s) in %ss: %d passed, %d partial, %d skipped, %d failed.\n' \
    "$TOTAL" "$ELAPSED" "$PASSED" "$PARTIAL" "$SKIPPED" "$FAILED"

  if [[ $SKIPPED -gt 0 ]]; then
    printf '\nWholly skipped (no coverage in this run — investigate toolchain gap):\n'
    for f in "${SKIPPED_FILES[@]}"; do
      printf '  - %s\n' "$f"
    done
  fi

  if [[ $PARTIAL -gt 0 ]]; then
    printf '\nPartial coverage (subset of cases skipped):\n'
    for f in "${PARTIAL_FILES[@]}"; do
      printf '  - %s\n' "$f"
    done
  fi

  # Slowest tests — useful signal for tuning JOBS, identifying flake risk,
  # and deciding what to fix when the suite gets too slow. Top 5 by ms.
  # Uses sort -rn with a tab separator so paths-with-spaces (rare here)
  # don't break the column split. Skipped when fewer than 5 tests ran.
  if [[ $TOTAL -ge 5 ]]; then
    printf '\nSlowest tests:\n'
    for t in "${TESTS[@]}"; do
      base="${t//\//_}"
      ms_file="$RESULTS_DIR/$base.log.ms"
      ms=0
      [[ -r "$ms_file" ]] && ms=$(<"$ms_file")
      printf '%s\t%s\n' "$ms" "$t"
    done | sort -rn | head -5 | awk -F'\t' '{printf "  %6d ms  %s\n", $1, $2}'
  fi

  # --- Walltime budget (per .claude/rules/bash/testing.md "Walltime budget") ----
  #
  # Soft cap (advisory): warns when any test exceeds BASH_TEST_WALLTIME_SOFT_MS.
  #   Always-on; never fails the run. Useful for visibility under JOBS=8 on Git
  #   Bash where MSYS2 fork tax inflates per-test wall by ~2× vs Linux.
  #
  # Hard cap (blocking, gated): exits non-zero when any test exceeds
  #   BASH_TEST_WALLTIME_HARD_MS AND BASH_TEST_WALLTIME_HARD_ENABLED=true.
  #   Default disabled — only the pre-push lefthook lane enables it.
  #
  # Override examples (per-session):
  #   BASH_TEST_WALLTIME_SOFT_MS=60000 bash tools/run-shell-tests.sh
  #   BASH_TEST_WALLTIME_HARD_ENABLED=true bash tools/run-shell-tests.sh
  SOFT_MS="${BASH_TEST_WALLTIME_SOFT_MS:-$BASH_TEST_WALLTIME_SOFT_MS_DEFAULT}"
  HARD_MS="${BASH_TEST_WALLTIME_HARD_MS:-$BASH_TEST_WALLTIME_HARD_MS_DEFAULT}"
  HARD_ENABLED="${BASH_TEST_WALLTIME_HARD_ENABLED:-false}"
  [[ $SOFT_MS =~ ^[0-9]+$ ]] || SOFT_MS="$BASH_TEST_WALLTIME_SOFT_MS_DEFAULT"
  [[ $HARD_MS =~ ^[0-9]+$ ]] || HARD_MS="$BASH_TEST_WALLTIME_HARD_MS_DEFAULT"

  SOFT_VIOLATIONS=()
  HARD_VIOLATIONS=()
  for t in "${TESTS[@]}"; do
    base="${t//\//_}"
    ms_file="$RESULTS_DIR/$base.log.ms"
    ms=0
    [[ -r "$ms_file" ]] && ms=$(<"$ms_file")
    [[ $ms =~ ^[0-9]+$ ]] || ms=0
    if [[ $ms -ge $HARD_MS ]]; then
      HARD_VIOLATIONS+=("$ms	$t")
    elif [[ $ms -ge $SOFT_MS ]]; then
      SOFT_VIOLATIONS+=("$ms	$t")
    fi
  done

  if [[ ${#SOFT_VIOLATIONS[@]} -gt 0 || ${#HARD_VIOLATIONS[@]} -gt 0 ]]; then
    printf '\nWalltime budget violations (soft=%dms hard=%dms):\n' "$SOFT_MS" "$HARD_MS"
    if [[ ${#HARD_VIOLATIONS[@]} -gt 0 ]]; then
      printf '%s\n' "${HARD_VIOLATIONS[@]}" \
        | sort -rn | awk -F'\t' -v hard="$HARD_MS" \
        '{printf "  HARD (>%dms)  %6d ms  %s\n", hard, $1, $2}'
    fi
    if [[ ${#SOFT_VIOLATIONS[@]} -gt 0 ]]; then
      printf '%s\n' "${SOFT_VIOLATIONS[@]}" \
        | sort -rn | awk -F'\t' -v soft="$SOFT_MS" \
        '{printf "  WARN (>%dms)  %6d ms  %s\n", soft, $1, $2}'
    fi
  fi

  # --- Observability: shell-test-timings.jsonl (schema: docs/conventions/shell-test-timings-schema.md;
  #     shared mechanics: .claude/rules/observability/conventions.md)
  #
  # Append one JSONL line per test file plus one __total__ summary line.
  # Gated by HOOK_OBSERVABILITY_LOG_ENABLED + HOOK_SHELL_TEST_TIMING_ENABLED
  # (both default false). Atomic per-line via `flock -x -w 1` against
  # <file>.lock — 1s timeout drops the line on contention (best-effort,
  # matches `hook::record_event` convention).
  #
  # Privacy: test_file is repo-relative path; never includes test content,
  # fixture data, env values. branch + cwd from hook::repo_root-equivalent
  # derivation; no user-content fields.
  if [[ "${HOOK_OBSERVABILITY_LOG_ENABLED:-false}" == "true" &&
    "${HOOK_SHELL_TEST_TIMING_ENABLED:-false}" == "true" ]]; then
    # CLAUDE_PROJECT_DIR override mirrors observability/conventions.md "Storage" convention
    # so this runner is testable (point at a tmpdir) without writing to the
    # real repo's observability log.
    obs_root="${CLAUDE_PROJECT_DIR:-$REPO_ROOT}"
    jsonl_file="$obs_root/.claude/observability/shell-test-timings.jsonl"
    mkdir -p "$(dirname "$jsonl_file")" 2>/dev/null || true
    ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null) || ts=""
    branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null | tr -d '\r') || branch=""
    cwd_rel="${PWD#"$REPO_ROOT"}"
    cwd_rel="${cwd_rel#/}"
    [[ -z "$cwd_rel" ]] && cwd_rel="."
    runner_total_ms=$(awk -v s="$START_EPOCH" -v e="$END_EPOCH" \
      'BEGIN{printf "%d", (e-s)*1000}' 2>/dev/null) || runner_total_ms=0

    # Build the JSONL block in a temp file, then either flock-append or
    # raw-append. Concurrent runners (multiple developers, parallel CI jobs)
    # are rare for shell tests — best-effort atomicity is sufficient per
    # observability/conventions.md "Concurrency" (kernel O_APPEND atomicity for small writes).
    jsonl_tmp="$RESULTS_DIR/timings.jsonl"
    : >"$jsonl_tmp"
    for t in "${TESTS[@]}"; do
      base="${t//\//_}"
      ms_file="$RESULTS_DIR/$base.log.ms"
      log="$RESULTS_DIR/$base.log"
      ms=0
      [[ -r "$ms_file" ]] && ms=$(<"$ms_file")
      [[ $ms =~ ^[0-9]+$ ]] || ms=0
      pc=0 sc=0
      [[ -r "$log" ]] && read -r pc sc \
        <<<"$(awk '/^PASS: /{p++} /^SKIP: /{s++} END{printf "%d %d", p + 0, s + 0}' "$log" 2>/dev/null)"
      rc=255
      [[ -r "$log.rc" ]] && rc=$(<"$log.rc")
      [[ $rc -eq 0 ]] && fc=0 || fc=1
      jq -nc \
        --arg ts "$ts" \
        --arg tf "$t" \
        --argjson dur "$ms" \
        --argjson pc "$pc" \
        --argjson sc "$sc" \
        --argjson fc "$fc" \
        --argjson rj "$JOBS" \
        --argjson rt "$runner_total_ms" \
        --arg br "$branch" \
        --arg cwd "$cwd_rel" \
        '{ts:$ts,test_file:$tf,duration_ms:$dur,pass_count:$pc,skip_count:$sc,fail_count:$fc,runner_jobs:$rj,runner_total_ms:$rt,branch:$br,cwd:$cwd}' \
        2>/dev/null >>"$jsonl_tmp"
    done
    # Total summary line
    jq -nc \
      --arg ts "$ts" \
      --argjson dur "$runner_total_ms" \
      --argjson pc "$PASSED" \
      --argjson sc "$SKIPPED" \
      --argjson fc "$FAILED" \
      --argjson rj "$JOBS" \
      --arg br "$branch" \
      --arg cwd "$cwd_rel" \
      '{ts:$ts,test_file:"__total__",duration_ms:$dur,pass_count:$pc,skip_count:$sc,fail_count:$fc,runner_jobs:$rj,runner_total_ms:$dur,branch:$br,cwd:$cwd}' \
      2>/dev/null >>"$jsonl_tmp"

    # Append. Prefer flock when available (defensive against concurrent runs);
    # fall back to raw append on Git Bash where util-linux flock is absent.
    # The full block is one atomic append from cat — order within preserved.
    if command -v flock >/dev/null 2>&1; then
      flock -x -w 1 "$jsonl_file.lock" sh -c 'cat "$1" >>"$2"' _ "$jsonl_tmp" "$jsonl_file" 2>/dev/null \
        || cat "$jsonl_tmp" >>"$jsonl_file" 2>/dev/null
    else
      cat "$jsonl_tmp" >>"$jsonl_file" 2>/dev/null
    fi
  fi

  if [[ $FAILED -eq 0 ]]; then
    if [[ "$HARD_ENABLED" == "true" && ${#HARD_VIOLATIONS[@]} -gt 0 ]]; then
      printf '\n%d test file(s) exceeded hard walltime cap (%dms). BASH_TEST_WALLTIME_HARD_ENABLED=true blocks.\n' \
        "${#HARD_VIOLATIONS[@]}" "$HARD_MS" >&2
      exit 1
    fi
    exit 0
  fi

  printf '\n%d of %d test file(s) failed:\n' "$FAILED" "$TOTAL" >&2
  for f in "${FAILED_FILES[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
  exit 1
}
