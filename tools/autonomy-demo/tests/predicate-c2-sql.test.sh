#!/usr/bin/env bash
# DuckDB-backed integration test for predicate-c2.sql. SEPARATE from the pure-bash gate
# suite (tests/run-tests.sh and gate.yml are jq + coreutils + git only — NO duckdb) and
# a distinct TIER, not a second way of doing the same thing: the mature-scoped span/count
# eligibility is SQL that only duckdb can exercise, and the pure suite structurally can't
# host it. Kept skip-guarded so it never breaks a no-duckdb environment; gate.yml still
# LINTS this file (shellcheck globs tests/*.sh) but does not RUN it, so it currently runs
# nowhere automatically — wiring it into a duckdb-equipped CI job is a gate.yml follow-up.
#
# Guards the burst+straggler regression the maturity guard exists to block: 20 mature
# completions clustered in a few days plus one young straggler far later must NOT satisfy
# the count and span gates on DISJOINT evidence (the span reverting from
# `MIN(...) FILTER (WHERE completion_mature)` back to plain `MIN(...)` would silently
# re-open it — nothing in the pure suite catches that).
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

# eval_field <fixture.jsonl> <field> — run predicate-c2.sql over the fixture, echo one
# output field. Mirrors predicate-c2.sh's sed substitution of __JOIN_PATH__ and
# __WINDOW_START__ (window set well before the fixtures so it never filters them).
eval_field() {
  local jp sql
  jp="$(to_native "$1")"
  sql="$(sed -e "s#__JOIN_PATH__#${jp}#g" -e "s#__WINDOW_START__#2026-06-01T00:00:00Z#g" "$SQL")"
  duckdb -json -c "$sql" | jq -r ".[0].$2"
}
eval_eligible() { eval_field "$1" predicate_eligible; }

# row <issue> <completed-day> <mature-bool> — one join row (gate success, unreverted).
row() {
  jq -cn --arg u "https://github.com/o/r/issues/$1" --arg r "scheduled-$1" \
    --arg ca "${2}T00:00:00Z" --argjson m "$3" \
    '{item_url:$u, run_id:$r, fire_kind:"scheduled", fire_attested:true,
      completed_at:$ca, gate_conclusion:"success", reverted:null, completion_mature:$m}'
}

# krow <issue> <completed-day> <fire-kind> <attested-bool> — like row, but with an
# explicit fire_kind + fire_attested (labeled/manual cohort rows, scratch#42); always
# mature so a leak into the eligibility aggregates would be maximally visible.
krow() {
  jq -cn --arg u "https://github.com/o/r/issues/$1" --arg r "${3}-$1" \
    --arg ca "${2}T00:00:00Z" --arg k "$3" --argjson a "$4" \
    '{item_url:$u, run_id:$r, fire_kind:$k, fire_attested:$a,
      completed_at:$ca, gate_conclusion:"success", reverted:null, completion_mature:true}'
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

# labeled cohort (scratch#42): attested event-driven completions are SURFACED
# (completions_labeled_attested) but must not enter the eligibility input set until
# activation. Take the INELIGIBLE burst fixture (20 mature clustered in 2 days) and add
# an attested, MATURE labeled completion 8 days out: were labeled rows leaking into the
# rows CTE, that row would establish the >=7-day span and 21st completion exactly like
# the positive control — so the fixture stays INELIGIBLE only while the exclusion holds.
lab="$tmp/labeled.jsonl"
{ cat "$burst"; krow 77 "2026-07-09" labeled true; } >"$lab"
assert_eq "predicate: an attested labeled completion is surfaced (count 1)" \
  "$(eval_field "$lab" completions_labeled_attested)" "1"
assert_eq "predicate: an attested labeled completion cannot enter the eligibility input set (still INELIGIBLE)" \
  "$(eval_eligible "$lab")" "false"
# The burst fixture holds 21 scheduled rows (20 mature + the young straggler); the mature
# labeled row would read 22 raw / 21 mature if it leaked into the scheduled aggregates.
assert_eq "predicate: labeled row absent from the raw scheduled completion count (21, not 22)" \
  "$(eval_field "$lab" completions)" "21"
assert_eq "predicate: labeled row absent from the mature completion count (20, not 21)" \
  "$(eval_field "$lab" completions_mature)" "20"

# unattested labeled and manual rows count NOWHERE: not in the labeled surface column
# (fail-closed on attestation, like the scheduled path) and not in eligibility.
lab_neg="$tmp/labeled-neg.jsonl"
{ cat "$burst"; krow 78 "2026-07-09" labeled false; krow 79 "2026-07-09" manual true; } >"$lab_neg"
assert_eq "predicate: an UNATTESTED labeled completion is not surfaced (count 0)" \
  "$(eval_field "$lab_neg" completions_labeled_attested)" "0"
assert_eq "predicate: manual/unattested rows leave eligibility untouched (still INELIGIBLE)" \
  "$(eval_eligible "$lab_neg")" "false"

if [[ "$fail" -ne 0 ]]; then
  echo "predicate-c2.sql duckdb test: FAILED" >&2
  exit 1
fi
echo "predicate-c2.sql duckdb test: all passed"
