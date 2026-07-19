# Longest-first test scheduling — sourced by run.sh, not executed directly.
# shellcheck source=run-policy.sh
# shellcheck disable=SC2154  # BASH_TEST_SCHEDULER_DEFAULT_PRIORITY_MS from run-policy.sh when sourced

# Round-3 A6: longest-first scheduling.
# Under JOBS=N parallelism, suite walltime is bounded by the longest test
# that starts LAST in the queue. Alphabetical glob order dispatches tests by
# name (uncorrelated with walltime). Starting the longest tests FIRST overlaps
# them with shorter tests filling around, reducing tail walltime.
#
# Reads tests/shell/walltime-baseline.json for ms_p95 per file. Files not in
# baseline get the median p95 as a default (so unknown files sort in the
# middle rather than dispatched dead-last).
#
# Replay loop later uses original alphabetical order — log determinism kept.
# Kill switch: BASH_TEST_SCHEDULER_LONGEST_FIRST_ENABLED=false.
sort_tests_longest_first() {
  local baseline="tests/shell/walltime-baseline.json"
  [[ "${BASH_TEST_SCHEDULER_LONGEST_FIRST_ENABLED:-true}" == "true" ]] || return 0
  [[ -f "$baseline" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local default_priority
  default_priority=$(jq -r --argjson default "$BASH_TEST_SCHEDULER_DEFAULT_PRIORITY_MS" '
    if (.tests | length) == 0 then $default
    else .tests | map(.ms_p95) | sort | .[length/2 | floor] end
  ' "$baseline" 2>/dev/null) || default_priority="$BASH_TEST_SCHEDULER_DEFAULT_PRIORITY_MS"

  # Read baseline ms_p95 into an associative array: filepath → ms_p95.
  declare -A priority
  local file ms
  while IFS=$'\t' read -r file ms; do
    [[ -n "$file" ]] && priority["$file"]="$ms"
  done < <(jq -r '.tests[] | "\(.file)\t\(.ms_p95)"' "$baseline" 2>/dev/null)

  # Annotate each test with priority, sort numerically-descending, strip prefix.
  local sorted=() t ms_for_t
  while IFS= read -r t; do
    [[ -n "$t" ]] && sorted+=("$t")
  done < <(
    for t in "${TESTS[@]}"; do
      ms_for_t="${priority[$t]:-$default_priority}"
      printf '%s\t%s\n' "$ms_for_t" "$t"
    done | sort -t$'\t' -k1,1 -rn | cut -f2-
  )

  if [[ ${#sorted[@]} -eq ${#TESTS[@]} ]]; then
    TESTS=("${sorted[@]}")
  fi
}
