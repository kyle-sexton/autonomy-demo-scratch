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

store="${1:-$DRAIN_OTEL_STORE}"
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
i=0
while [[ "$i" -lt "$n" ]]; do
  issue="$(jq -r ".[$i].issue" <<<"$complete_rows")"
  completed_at="$(jq -r ".[$i].ts // empty" <<<"$complete_rows")"
  i=$((i + 1))
  [[ -n "$issue" && "$issue" != "null" ]] || continue
  # verify-join emits a JSON array of joined rows for this item; enrich each with
  # the run's completion timestamp and flatten to newline-delimited.
  set +e
  row_json="$("$SCRIPT_DIR/verify-join.sh" "$issue" "$store" 2>/dev/null)"
  vj_rc=$?
  set -e
  [[ "$vj_rc" -eq 0 && -n "$row_json" ]] || continue
  printf '%s' "$row_json" \
    | jq -c --arg ca "$completed_at" '.[]? | . + {completed_at: $ca}' >>"$join_all" || true
done

if [[ ! -s "$join_all" ]]; then
  echo '[{"completions":0,"window_span_days":0,"gate_pass_rate":0.0,"human_revert_count":0,"predicate_eligible":false}]'
  exit 0
fi

join_path="$join_all"
if command -v cygpath >/dev/null 2>&1; then join_path="$(cygpath -m "$join_all")"; fi
sql="$(sed "s#__JOIN_PATH__#${join_path}#g" "$SCRIPT_DIR/predicate-c2.sql")"
duckdb -json -c "$sql"
