#!/usr/bin/env bash
# Acceptance proof for the drain dogfood wiring: for one item+run, join the
# wrapper span, the session's native telemetry, the return-accounting record,
# the deterministic-gate outcome (read from GitHub's check-run API — an
# independent surface, never an agent-written file), and the PR merge state.
#
# Join key is the distinct pair (item_url, run_id): completeness is per fired
# run, not raw row count. jq projects each source to a flat table; DuckDB joins.
# Revert detection is left as TODO(#778) (see the `reverted` column).
#
# Usage: verify-join.sh <issue-number> [<session-store-dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

issue="${1:?usage: verify-join.sh <issue-number> [<session-store-dir>]}"
store="${2:-$DRAIN_OTEL_STORE}"

owner_repo="$(drain_owner_repo)"
item_url="$(drain_item_url "$owner_repo" "$issue")"
artifact_dir="$DRAIN_ARTIFACT_DIR"
mkdir -p "$artifact_dir"

# wrapper spans -> flat (item_url, run_id, trace_id, schema_url)
jq -c '.resourceSpans[] as $rs | $rs.scopeSpans[].spans[] as $s |
  ([$s.attributes[]? | select(.key == "autonomy.work_item.url").value.stringValue] | first) as $u |
  ([$s.attributes[]? | select(.key == "cicd.pipeline.run.id").value.stringValue] | first) as $rid |
  select($u != null) |
  {item_url: $u, run_id: $rid, trace_id: $s.traceId, schema_url: $rs.schemaUrl}' \
  "$DRAIN_PIPELINE" >"${artifact_dir}/flat-wrapper.jsonl"

# native session metrics -> flat (item_url, run_id), one row per resource emission
jq -c '.resourceMetrics[]? |
  ([.resource.attributes[]? | select(.key == "autonomy.work_item.url").value.stringValue] | first) as $u |
  ([.resource.attributes[]? | select(.key == "cicd.pipeline.run.id").value.stringValue] | first) as $rid |
  select($u != null) | {item_url: $u, run_id: $rid}' \
  "${store}/cc-metrics.json" >"${artifact_dir}/flat-session.jsonl"

# return-accounting record from the item's marker comment (carries run_id,
# work_class, fire_kind, pr_url, attested)
# shellcheck disable=SC2016  # the backtick fence delimiters are literal, not expansions
gh issue view "$issue" --json comments \
  --jq '[.comments[].body | select(contains("autonomy:return-accounting:v1"))][0]' \
  | sed -n '/^```json$/,/^```$/p' | sed '1d;$d' >"${artifact_dir}/return-record.json"

# gate outcome (check-run API, keyed on the PR head SHA) + merge state, resolved
# from the PR the return record names. All fields default null when unavailable
# (PR not yet open, gate pending, not yet merged).
pr_url="$(jq -r '.pr_url // empty' "${artifact_dir}/return-record.json" 2>/dev/null || true)"
run_id="$(jq -r '.run_id // empty' "${artifact_dir}/return-record.json" 2>/dev/null || true)"
head_sha="" merged_at="" merge_sha="" gate_conclusion=""
if [[ -n "$pr_url" ]]; then
  pr_json="$(gh pr view "$pr_url" --json headRefOid,mergedAt,mergeCommit 2>/dev/null || echo '{}')"
  head_sha="$(jq -r '.headRefOid // empty' <<<"$pr_json")"
  merged_at="$(jq -r '.mergedAt // empty' <<<"$pr_json")"
  merge_sha="$(jq -r '.mergeCommit.oid // empty' <<<"$pr_json")"
  if [[ -n "$head_sha" ]]; then
    gate_conclusion="$(gh api "repos/${owner_repo}/commits/${head_sha}/check-runs" \
      --jq "[.check_runs[] | select(.name == \"${DRAIN_GATE_CHECK_NAME}\")][0].conclusion // empty" \
      2>/dev/null || true)"
  fi
fi
jq -cn --arg u "$item_url" --arg r "$run_id" --arg pr "$pr_url" --arg hs "$head_sha" \
  --arg gc "$gate_conclusion" --arg ma "$merged_at" --arg ms "$merge_sha" \
  '{item_url: $u, run_id: $r,
    pr_url: (if $pr == "" then null else $pr end),
    head_sha: (if $hs == "" then null else $hs end),
    gate_conclusion: (if $gc == "" then null else $gc end),
    merged_at: (if $ma == "" then null else $ma end),
    merge_sha: (if $ms == "" then null else $ms end)}' \
  >"${artifact_dir}/flat-gate.json"

flat_dir="$artifact_dir"
if command -v cygpath >/dev/null 2>&1; then flat_dir="$(cygpath -m "$artifact_dir")"; fi

duckdb -json <<SQL
WITH wrapper AS (
  SELECT item_url, run_id, trace_id, schema_url
  FROM read_json_auto('${flat_dir}/flat-wrapper.jsonl', format='newline_delimited')
),
session AS (
  SELECT item_url, run_id, COUNT(*) AS session_emissions
  FROM read_json_auto('${flat_dir}/flat-session.jsonl', format='newline_delimited')
  GROUP BY 1, 2
),
record AS (
  SELECT work_item_url AS item_url, run_id, work_class, fire_kind, attested, pr_url
  FROM read_json_auto('${flat_dir}/return-record.json')
),
gate AS (
  SELECT item_url, run_id, head_sha, gate_conclusion, merged_at, merge_sha
  FROM read_json_auto('${flat_dir}/flat-gate.json')
)
SELECT w.item_url, w.run_id, w.trace_id, w.schema_url,
       s.session_emissions,
       r.work_class, r.fire_kind, r.attested, r.pr_url,
       g.head_sha, g.gate_conclusion, g.merged_at, g.merge_sha,
       NULL AS reverted -- TODO(#778): revert detection (later commit/PR reverting merge_sha)
FROM wrapper w
JOIN session s USING (item_url, run_id)
JOIN record r USING (item_url, run_id)
LEFT JOIN gate g USING (item_url, run_id)
WHERE w.item_url = '${item_url}';
SQL
