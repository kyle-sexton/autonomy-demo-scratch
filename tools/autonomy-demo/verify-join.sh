#!/usr/bin/env bash
# Acceptance proof for the fleet dogfood wiring: one work item joins the wrapper
# span, the session's native telemetry, and the return-accounting record on the
# telemetry contract's Pillar-2 attribute (string-equal canonical item URL).
# jq projects each source to a flat table; DuckDB performs the join (the same
# query-side join shape the WP3 demo established).
#
# Usage: verify-join.sh <issue-number> [<session-store-dir>]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
issue="$1"
store="${2:-${CC_OTEL_STORE:-C:/ProgramData/local-otel/cc-store}}"

owner_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
item_url="https://github.com/${owner_repo}/issues/${issue}"
artifact_dir="${repo_root}/.artifacts"

# wrapper spans -> flat (item_url, trace_id, schema_url)
jq -c '.resourceSpans[] as $rs | $rs.scopeSpans[].spans[] as $s |
  ($s.attributes[] | select(.key == "autonomy.work_item.url").value.stringValue) as $u |
  {item_url: $u, trace_id: $s.traceId, schema_url: $rs.schemaUrl}' \
  "${artifact_dir}/pipeline.jsonl" > "${artifact_dir}/flat-wrapper.jsonl"

# native session metrics -> flat (item_url) one row per resource emission
jq -c '.resourceMetrics[]? |
  (.resource.attributes[]? | select(.key == "autonomy.work_item.url").value.stringValue) as $u |
  select($u != null) | {item_url: $u}' \
  "${store}/cc-metrics.json" > "${artifact_dir}/flat-session.jsonl"

# return-accounting record from the item's marker comment
# shellcheck disable=SC2016  # the backtick fence delimiters are literal, not expansions
gh issue view "$issue" --json comments \
  --jq '[.comments[].body | select(contains("autonomy:return-accounting:v1"))][0]' \
  | sed -n '/^```json$/,/^```$/p' | sed '1d;$d' > "${artifact_dir}/return-record.json"

flat_dir="$artifact_dir"
if command -v cygpath >/dev/null 2>&1; then flat_dir="$(cygpath -m "$artifact_dir")"; fi

duckdb -json <<SQL
WITH wrapper AS (
  SELECT item_url, trace_id, schema_url
  FROM read_json_auto('${flat_dir}/flat-wrapper.jsonl', format='newline_delimited')
),
session AS (
  SELECT item_url, COUNT(*) AS session_emissions
  FROM read_json_auto('${flat_dir}/flat-session.jsonl', format='newline_delimited')
  GROUP BY 1
),
record AS (
  SELECT work_item_url AS item_url, attested
  FROM read_json_auto('${flat_dir}/return-record.json')
)
SELECT w.item_url, w.trace_id, w.schema_url, s.session_emissions, r.attested
FROM wrapper w
JOIN session s USING (item_url)
JOIN record  r USING (item_url)
WHERE w.item_url = '${item_url}';
SQL
