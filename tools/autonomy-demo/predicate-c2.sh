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

# Distinct COMPLETE runs (last status per run_id), with their completion ts.
if [[ -f "$DRAIN_RUN_STATE" ]]; then
  complete_rows="$(jq -sc '
    reduce .[] as $r ({}; .[$r.run_id] = ((.[$r.run_id] // {}) + $r))
    | [.[] | select((.status // "") == "complete")]' "$DRAIN_RUN_STATE" 2>/dev/null || printf '[]')"
else
  complete_rows='[]'
fi

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
  echo '[{"completions":0,"window_span_days":0,"gate_pass_rate":0.0,"human_revert_count":0,"predicate_eligible":false}]'
  exit 0
fi

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
