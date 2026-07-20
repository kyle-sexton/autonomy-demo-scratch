#!/usr/bin/env bash
# Acceptance proof for the fleet dogfood wiring: one work item joins the wrapper
# span, the session's native telemetry, and the return-accounting record on the
# telemetry contract's Pillar-2 attribute (string-equal canonical item URL).
#
# Usage: verify-join.sh <issue-number> [<session-store-dir>]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
issue="$1"
store="${2:-${CC_OTEL_STORE:-C:/ProgramData/local-otel/cc-store}}"

owner_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
item_url="https://github.com/${owner_repo}/issues/${issue}"
artifact_dir="${repo_root}/.artifacts"

# return-accounting record, pulled from the item's marker comment
# shellcheck disable=SC2016  # the backtick fence delimiters are literal, not expansions
gh issue view "$issue" --json comments \
  --jq '[.comments[].body | select(contains("autonomy:return-accounting:v1"))][0]' \
  | sed -n '/^```json$/,/^```$/p' | sed '1d;$d' > "${artifact_dir}/return-record.json"

duckdb -json <<SQL
WITH wrapper AS (
  SELECT rs.unnest->>'schemaUrl'                                   AS schema_url,
         span.unnest->>'traceId'                                   AS trace_id,
         attr.unnest->'value'->>'stringValue'                      AS item_url
  FROM read_json_auto('${artifact_dir}/pipeline.jsonl', format='newline_delimited') j,
       UNNEST(j.resourceSpans) rs,
       UNNEST((rs.unnest->'scopeSpans')[1]->'spans') span,
       UNNEST(span.unnest->'attributes') attr
  WHERE attr.unnest->>'key' = 'autonomy.work_item.url'
),
session AS (
  SELECT attr.unnest->'value'->>'stringValue'                      AS item_url,
         COUNT(*)                                                  AS session_emissions
  FROM read_json_auto('${store}/cc-metrics.json', format='newline_delimited') j,
       UNNEST(j.resourceMetrics) rm,
       UNNEST(rm.unnest->'resource'->'attributes') attr
  WHERE attr.unnest->>'key' = 'autonomy.work_item.url'
  GROUP BY 1
),
record AS (
  SELECT work_item_url AS item_url, attested
  FROM read_json_auto('${artifact_dir}/return-record.json')
)
SELECT w.item_url, w.trace_id, w.schema_url, s.session_emissions, r.attested
FROM wrapper w
JOIN session s USING (item_url)
JOIN record  r USING (item_url)
WHERE w.item_url = '${item_url}';
SQL
