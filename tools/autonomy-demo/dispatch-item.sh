#!/usr/bin/env bash
# Production-path dispatch wrapper: lease one work item, run the agent session on it
# with the telemetry contract's join attribute + trace context injected, land the
# WP3 return-accounting record at close, and leave a joinable OTLP artifact trail.
#
# Standing session telemetry (exporters/endpoint) comes from the machine's own
# settings env, not from this wrapper; the wrapper injects only the per-item
# resource attribute and the trace context — per the #351 emission-source decision.
#
# Usage: dispatch-item.sh <issue-number> "<task prompt for the agent>"
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
issue="$1"
task_prompt="$2"

owner_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
item_url="https://github.com/${owner_repo}/issues/${issue}"

artifact_dir="${repo_root}/.artifacts"
mkdir -p "$artifact_dir"

# --- lease via the tracker seam (race-safe claim; TTL from the binding) -----
ttl_hours="$(jq -r '.config.lease_ttl_hours' "${repo_root}/.work-item-tracker.json")"
"${repo_root}/tools/work-item-tracker/adapters/github/claim.sh" \
  "github:${owner_repo}#${issue}" --ttl-hours "$ttl_hours"

# --- contract-authored wrapper span + trace context -------------------------
trace_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
span_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
start_ns="$(date +%s%N)"
export TRACEPARENT="00-${trace_id}-${span_id}-01"
export OTEL_RESOURCE_ATTRIBUTES="autonomy.work_item.url=${item_url}"

# --- the agent session (session telemetry rides the standing machine env) ---
set +e
claude -p "$task_prompt" --model opus
agent_rc=$?
set -e
end_ns="$(date +%s%N)"

cat >> "${artifact_dir}/pipeline.jsonl" <<JSON
{"resourceSpans":[{"schemaUrl":"https://opentelemetry.io/schemas/1.43.0","resource":{"attributes":[]},"scopeSpans":[{"scope":{"name":"autonomy-demo-dispatch"},"spans":[{"traceId":"${trace_id}","spanId":"${span_id}","name":"autonomy-dispatch","kind":2,"startTimeUnixNano":"${start_ns}","endTimeUnixNano":"${end_ns}","attributes":[{"key":"cicd.pipeline.run.id","value":{"stringValue":"local-${start_ns}"}},{"key":"autonomy.work_item.url","value":{"stringValue":"${item_url}"}}]}]}]}]}
JSON

if [ "$agent_rc" -ne 0 ]; then
  echo "agent session failed (rc=$agent_rc); item stays leased, no close record written" >&2
  exit "$agent_rc"
fi

# --- WP3 return-accounting record at close (marker-keyed, create-only) ------
if ! gh issue view "$issue" --json comments --jq '.comments[].body' | grep -qF 'autonomy:return-accounting:v1'; then
  request_url="$item_url"
  gh issue comment "$issue" --body-file - <<EOF
<!-- autonomy:return-accounting:v1 -->

\`\`\`json
{
  "schema_version": "1",
  "work_item_url": "${item_url}",
  "attested": false,
  "attestation_request": "${request_url}",
  "attestation_owner": { "identity": "kyle-sexton", "role": "requester" }
}
\`\`\`

@kyle-sexton This item was completed by autonomous work. Two questions:

1. **Would you have spent engineering effort on this anyway?** — \`yes\` / \`no\` / \`partial\`
2. **What would it have cost in manual eng-hours?** — \`<1h\` / \`1-4h\` / \`4h-1d\` / \`1d-1w\` / \`1w-1mo\` / \`>1mo\`

Reply to this comment with your answers (e.g. \`partial, 1-4h\`) — or start a new comment with \`attest:\` — or skip; a skip leaves the record unattested.
EOF
fi
gh issue close "$issue" --reason completed

echo "trace_id=${trace_id}"
echo "artifact=${artifact_dir}/pipeline.jsonl"
echo "item=${item_url}"
