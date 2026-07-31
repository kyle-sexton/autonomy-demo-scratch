#!/usr/bin/env bash
# DuckDB-backed integration test for predicate-c2.sql. SEPARATE from the pure-bash gate
# suite (tests/run-tests.sh and gate.yml are jq + coreutils + git only — NO duckdb) and
# a distinct TIER, not a second way of doing the same thing: the SQL-level eligibility
# filtering is something only duckdb can exercise, and the pure suite structurally can't
# host it. gate.yml LINTS this file (shellcheck globs tests/*.sh) but does not RUN it; the
# separate predicate-sql-test.yml workflow installs duckdb and runs it on any PR touching
# tools/autonomy-demo/**. The skip guard below keeps it harmless in a no-duckdb environment.
#
# Guards two regressions the pure suite cannot catch, both of which turn on WHICH rows the
# aggregates compute over:
#   - burst+straggler (merge maturity): 20 mature completions clustered in a few days plus
#     one YOUNG straggler far later must not satisfy the count and span gates on DISJOINT
#     evidence — the span reverting from `MIN(...) FILTER (WHERE completion_mature)` back to
#     plain `MIN(...)` would silently re-open it.
#   - corrected-run exclusion (scratch#60): a run that needed a delegated pre-merge
#     correction must leave the predicate's INPUT SET, not merely its completion count —
#     narrowing that back to a count-only filter would let a repaired run at the edge of the
#     window still establish the >=7-day span.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$TEST_DIR/../predicate-c2.sql"

if ! command -v duckdb >/dev/null 2>&1; then
  echo "SKIP - predicate-c2.sql duckdb integration test (duckdb not installed)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

to_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# eval_col <fixture.jsonl> <column> — run predicate-c2.sql over the fixture, echo one
# output column. Mirrors predicate-c2.sh's sed substitution of __JOIN_PATH__ and
# __WINDOW_START__ (window set well before the fixtures so it never filters them).
eval_col() {
  local jp sql
  jp="$(to_native "$1")"
  sql="$(sed -e "s#__JOIN_PATH__#${jp}#g" -e "s#__WINDOW_START__#2026-06-01T00:00:00Z#g" "$SQL")"
  duckdb -json -c "$sql" | jq -r ".[0].$2"
}
eval_eligible() { eval_col "$1" predicate_eligible; }

# row <issue> <completed-day> <mature-bool> [<corrected-bool>] — one join row (gate
# success, unreverted). `corrected` defaults false: the columns predicate-c2.sh writes on
# EVERY row must all be present here too, or the SQL's filters become binder errors.
row() {
  jq -cn --arg u "https://github.com/o/r/issues/$1" --arg r "scheduled-$1" \
    --arg ca "${2}T00:00:00Z" --argjson m "$3" --argjson c "${4:-false}" \
    '{item_url:$u, run_id:$r, fire_kind:"scheduled", fire_attested:true,
      completed_at:$ca, gate_conclusion:"success", reverted:null, completion_mature:$m,
      corrected:$c}'
}

assert_eq() { # <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    printf 'ok - %s\n' "$1"
  else
    fail=1
    printf 'not ok - %s\n  # expected=[%s] actual=[%s]\n' "$1" "$3" "$2"
  fi
}

# burst+straggler: 20 mature clustered in 2 days (07-01/07-02) + 1 YOUNG straggler 7 days
# later (07-09). Span over ALL rows would be 8 days (>=7) on disjoint evidence; span over
# MATURE rows is 1 day (<7) -> INELIGIBLE.
burst="$tmp/burst.jsonl"
: >"$burst"
for i in $(seq 1 20); do
  if (( i <= 10 )); then row "$i" "2026-07-01" true; else row "$i" "2026-07-02" true; fi
done >>"$burst"
row 99 "2026-07-09" false >>"$burst"
assert_eq "predicate: burst (20 mature in 2 days) + young straggler 7 days later is INELIGIBLE" \
  "$(eval_eligible "$burst")" "false"

# positive control: same burst but the straggler has matured -> 21 mature spanning 8 days
# -> ELIGIBLE. Guards against a gate stuck permanently false.
pos="$tmp/pos.jsonl"
jq -c 'if .run_id=="scheduled-99" then .completion_mature=true else . end' "$burst" >"$pos"
assert_eq "predicate: 21 mature spanning 8 days is ELIGIBLE (positive control)" \
  "$(eval_eligible "$pos")" "true"

# corrected-run exclusion (scratch#60): the run at the far edge of the window is mature and
# gate-green, but its PR needed a delegated pre-merge correction — so it is not an
# autonomous completion. Take the ELIGIBLE positive control above and mark ONLY that row
# corrected. Excluding it from the completion COUNT alone would leave 20 mature completions
# still spanning 8 days => eligible; excluding it from the INPUT SET leaves 20 clustered in
# 2 days => INELIGIBLE. That difference is the whole point of filtering in the rows CTE, and
# this pair is the only thing that catches a regression back to a count-only filter.
corr="$tmp/corrected.jsonl"
jq -c 'if .run_id=="scheduled-99" then .corrected=true else . end' "$pos" >"$corr"
assert_eq "predicate: a CORRECTED straggler cannot establish the >=7-day span (INELIGIBLE)" \
  "$(eval_eligible "$corr")" "false"
assert_eq "predicate: the corrected run is excluded from the completion count too (20, not 21)" \
  "$(eval_col "$corr" completions_mature)" "20"
assert_eq "predicate: window_span_days computes over autonomous completions only (1, not 8)" \
  "$(eval_col "$corr" window_span_days)" "1"
# Every aggregate, not just the count: a REVERT on a corrected run must not hold the gate
# shut either, since that run is not autonomous evidence in the first place. Same fixture
# with the corrected straggler reverted -> human_revert_count stays 0.
corr_rev="$tmp/corrected-reverted.jsonl"
jq -c 'if .run_id=="scheduled-99" then .corrected=true | .reverted="deadbeef" else . end' \
  "$pos" >"$corr_rev"
assert_eq "predicate: a corrected run's revert is outside the input set (revert count 0)" \
  "$(eval_col "$corr_rev" human_revert_count)" "0"

if [[ "$fail" -ne 0 ]]; then
  echo "predicate-c2.sql duckdb test: FAILED" >&2
  exit 1
fi
echo "predicate-c2.sql duckdb test: all passed"
