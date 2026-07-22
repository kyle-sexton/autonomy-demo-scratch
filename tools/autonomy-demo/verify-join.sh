#!/usr/bin/env bash
# Acceptance proof for the drain dogfood wiring: for one item+run, join the
# wrapper span, the session's native telemetry, the return-accounting record,
# the deterministic-gate outcome (read from GitHub's check-run API — an
# independent surface, never an agent-written file), and the PR merge state.
#
# Join key is the distinct pair (item_url, run_id): completeness is per fired
# run, not raw row count. jq projects each source to a flat table; DuckDB joins.
#
# Revert detection: a merged row is `reverted` when origin/main history AFTER the
# merge carries a commit reverting merge_sha ("This reverts commit <sha>"). The
# read is against origin/main; a `git fetch` below refreshes it before the lookup.
#
# Usage: verify-join.sh <issue-number> [<session-store-dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

issue="${1:?usage: verify-join.sh <issue-number> [<session-store-dir>]}"
store="${2:-}"
[[ -n "$store" ]] || store="$(drain_otel_store)"

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
head_sha="" merged_at="" merge_sha="" gate_conclusion="" reverted=""
if [[ -n "$pr_url" ]]; then
  # Fail-SOFT resolution: this join emits null fields when merge/gate state is
  # unavailable (PR not yet open, gate pending, not yet merged). A gh failure from the
  # shared helper (rc != 0) leaves the pre-initialized empties in place — same as the
  # prior inline `|| echo '{}'` — rather than aborting. (The revert path below is the
  # one that fails CLOSED, because revert status feeds the C2 eligibility gate.)
  if merge_state="$(drain_pr_merge_state "$pr_url")"; then
    IFS=$'\t' read -r head_sha merge_sha merged_at <<<"$merge_state"
  fi
  if [[ -n "$head_sha" ]]; then
    gate_conclusion="$(drain_gate_conclusion "$owner_repo" "$head_sha")" || gate_conclusion=""
  fi
  # Revert detection over origin/main. reverted = the SHA of the commit reverting
  # this merge, or null when confirmed unreverted. This FAILS CLOSED: revert status
  # feeds the C2 eligibility gate, so "could not determine" must NOT masquerade as
  # clean. A failed fetch or an unreadable range aborts the whole join (no row is
  # emitted with unknown revert status) rather than defaulting to null.
  #
  # DRAIN_SKIP_FETCH=1 (set by predicate-c2.sh, which fetches once before its loop)
  # skips the per-invocation fetch; the abort-on-unreadable-range check below still
  # applies, so completeness is preserved either way.
  if [[ -n "$merge_sha" ]]; then
    if [[ "${DRAIN_SKIP_FETCH:-}" != "1" ]]; then
      if ! git -C "$DRAIN_REPO_ROOT" fetch --quiet origin 2>/dev/null; then
        echo "verify-join: FATAL could not fetch origin; revert status undeterminable for merge ${merge_sha} (evidence completeness is required) — aborting" >&2
        exit 1
      fi
    fi
    if ! reverted="$(drain_revert_sha "$DRAIN_REPO_ROOT" "$merge_sha" "origin/main")"; then
      echo "verify-join: FATAL revert lookup failed for merge ${merge_sha} (origin/main range unreadable) — aborting rather than emitting unknown revert status" >&2
      exit 1
    fi
  fi
fi
jq -cn --arg u "$item_url" --arg r "$run_id" --arg pr "$pr_url" --arg hs "$head_sha" \
  --arg gc "$gate_conclusion" --arg ma "$merged_at" --arg ms "$merge_sha" --arg rv "$reverted" \
  '{item_url: $u, run_id: $r,
    pr_url: (if $pr == "" then null else $pr end),
    head_sha: (if $hs == "" then null else $hs end),
    gate_conclusion: (if $gc == "" then null else $gc end),
    merged_at: (if $ma == "" then null else $ma end),
    merge_sha: (if $ms == "" then null else $ms end),
    reverted: (if $rv == "" then null else $rv end)}' \
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
  SELECT item_url, run_id, head_sha, gate_conclusion, merged_at, merge_sha, reverted
  FROM read_json_auto('${flat_dir}/flat-gate.json')
)
SELECT w.item_url, w.run_id, w.trace_id, w.schema_url,
       s.session_emissions,
       r.work_class, r.fire_kind, r.attested, r.pr_url,
       g.head_sha, g.gate_conclusion, g.merged_at, g.merge_sha,
       g.reverted
FROM wrapper w
JOIN session s USING (item_url, run_id)
JOIN record r USING (item_url, run_id)
LEFT JOIN gate g USING (item_url, run_id)
WHERE w.item_url = '${item_url}';
SQL
