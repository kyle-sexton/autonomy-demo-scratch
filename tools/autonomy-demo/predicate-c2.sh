#!/usr/bin/env bash
# Runner for the C2 promotion-predicate stub. Materializes the combined per-run
# join output across all COMPLETE drain runs (reusing verify-join.sh as the one
# source of a joined row -- no duplicated gate/merge logic), then evaluates
# predicate-c2.sql over it. Queries live GitHub gate/merge state, so it needs an
# authenticated gh; it is a read-only reporter with no side effects on the queue.
#
# Usage: predicate-c2.sh [<session-store-dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

store="${1:-}"
[[ -n "$store" ]] || store="$(drain_otel_store)"
join_all="${DRAIN_ARTIFACT_DIR}/join-all.jsonl"
mkdir -p "$DRAIN_ARTIFACT_DIR"
: >"$join_all"

# Distinct COMPLETE runs (last status per run_id), with their completion ts, via the
# shared enumerator (same reduction watch-demotion.sh uses). Fail-SOFT: a missing OR
# unparseable run-state file degrades to zero completions (reported not-eligible below),
# matching this reporter's read-only, no-abort posture.
complete_rows="$(drain_complete_runs "$DRAIN_RUN_STATE" 2>/dev/null || printf '[]')"

n="$(jq 'length' <<<"$complete_rows")"

# verify-join's revert detection reads origin/main; refresh it ONCE here (rather
# than once per row) and fail CLOSED: revert status feeds the C2 eligibility gate,
# so an un-refreshable origin aborts rather than counting stale/unknown reverts as
# clean. DRAIN_SKIP_FETCH tells verify-join not to re-fetch per invocation.
if [[ "$n" -gt 0 ]]; then
  if ! git -C "$DRAIN_REPO_ROOT" fetch --quiet origin 2>/dev/null; then
    echo "predicate-c2: FATAL could not fetch origin; revert status undeterminable (evidence completeness is required) — aborting" >&2
    exit 1
  fi
  export DRAIN_SKIP_FETCH=1
fi

i=0
while [[ "$i" -lt "$n" ]]; do
  issue="$(jq -r ".[$i].issue" <<<"$complete_rows")"
  completed_at="$(jq -r ".[$i].ts // empty" <<<"$complete_rows")"
  i=$((i + 1))
  [[ -n "$issue" && "$issue" != "null" ]] || continue
  # verify-join emits a JSON array of joined rows for this item; enrich each with
  # the run's completion timestamp and flatten to newline-delimited. Its stderr is
  # NOT swallowed: a non-zero exit on a COMPLETE run (e.g. verify-join aborting on
  # undeterminable revert status) is a hard evidence-completeness failure and must
  # abort the predicate, never silently drop the row from the gate inputs.
  set +e
  row_json="$("$SCRIPT_DIR/verify-join.sh" "$issue" "$store")"
  vj_rc=$?
  set -e
  if [[ "$vj_rc" -ne 0 ]]; then
    echo "predicate-c2: FATAL verify-join failed (rc=$vj_rc) for complete run issue #${issue}; evidence incomplete — aborting" >&2
    exit "$vj_rc"
  fi
  [[ -n "$row_json" ]] || continue
  printf '%s' "$row_json" \
    | jq -c --arg ca "$completed_at" '.[]? | . + {completed_at: $ca}' >>"$join_all" || true
done

if [[ ! -s "$join_all" ]]; then
  echo '[{"completions":0,"completions_mature":0,"window_span_days":0,"gate_pass_rate":0.0,"human_revert_count":0,"predicate_eligible":false}]'
  exit 0
fi

# Fire-origin attestation. The C2 predicate must NOT trust the fire_kind stamp: the
# Desktop task hardcodes --fire-kind, so a manual "Run now" self-stamps as scheduled.
# Attest each complete run's ORIGIN from outer-session transcript evidence (one
# invocation over all run_ids), record positives durably, then enrich every join row
# with fire_attested. An unattested row is a DESIGNED exclusion, not evidence
# breakage, so it WARNS and the SQL drops it — it does NOT abort (contrast the
# verify-join FATAL paths above, which stay as they are).
# `tr -d '\r'` at this jq boundary: jq.exe emits CRLF under Windows text-mode stdout
# (the same boundary drain_select_candidates guards), and a trailing CR rides into
# each run_id — the attestation regex would then reject every real run_id.
run_ids="$(jq -r '.[].run_id // empty' <<<"$complete_rows" | tr -d '\r' | sort -u)"
attest_ndjson=""
if [[ -n "$run_ids" ]]; then
  mapfile -t rid_args <<<"$run_ids"
  attest_ndjson="$("$SCRIPT_DIR/attest-fire-origin.sh" --record "${rid_args[@]}")"
fi

# One stderr warning per unattested run_id; the reason travels in the NDJSON row.
if [[ -n "$attest_ndjson" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rid="$(jq -r '.run_id' <<<"$line")"
    reason="$(jq -r '.reason' <<<"$line")"
    echo "predicate-c2: run ${rid} fire-origin unattested (${reason}) — excluded from predicate" >&2
  done < <(printf '%s\n' "$attest_ndjson" | jq -c 'select(.fire_attested == false)')
fi

# Enrich each join row with fire_attested by run_id (default false when the run_id is
# absent from the attestation output — fail closed). Rewrite join_all in place: DuckDB
# infers the schema from these rows, so the column must be present on EVERY row (a
# first row missing it would drop the column and break the SQL's fire_attested filter).
attest_map="$(printf '%s\n' "$attest_ndjson" \
  | jq -c -s 'map(select(.run_id != null) | {(.run_id): .fire_attested}) | add // {}')"
jq -c --argjson m "$attest_map" '. + {fire_attested: ($m[.run_id] // false)}' \
  "$join_all" >"${join_all}.attested"
mv "${join_all}.attested" "$join_all"

# Enrich each join row with completion_mature: true when the row's PR merged at least
# DRAIN_MERGE_MATURITY_S before now. The SQL's >=20 threshold counts only mature rows;
# an unmerged or freshly merged completion is simply not YET mature (not an error).
# The maturity decision is computed here via the shared drain_merge_is_mature so it
# lives in ONE place and stays unit-testable without duckdb (tests/run-tests.sh has no
# duckdb). Like fire_attested, the column must be on EVERY row (duckdb infers the
# schema from these rows), so every row is rewritten. merged_at comes from verify-join
# (GitHub PR data), null when unmerged; `tr -d '\r'` guards the jq.exe CRLF boundary.
now_epoch="$(date -u +%s)"
: >"${join_all}.mature"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  merged_at="$(jq -r '.merged_at // ""' <<<"$line" | tr -d '\r')"
  mature="$(drain_merge_is_mature "$merged_at" "$now_epoch")"
  jq -c --argjson mt "$mature" '. + {completion_mature: $mt}' <<<"$line"
done <"$join_all" >>"${join_all}.mature"
mv "${join_all}.mature" "$join_all"

join_path="$join_all"
if command -v cygpath >/dev/null 2>&1; then join_path="$(cygpath -m "$join_all")"; fi

# Escape the substituted values for a sed replacement string: a literal backslash,
# ampersand, or the `#` delimiter would otherwise be reinterpreted (a path with any
# of these would corrupt the query). Values are trusted here, but this closes the
# injection surface cheaply while the file is being touched.
sed_repl_escape() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
sql="$(sed -e "s#__JOIN_PATH__#$(sed_repl_escape "$join_path")#g" \
  -e "s#__WINDOW_START__#$(sed_repl_escape "$DRAIN_WINDOW_START_UTC")#g" \
  "$SCRIPT_DIR/predicate-c2.sql")"
duckdb -json -c "$sql"
