#!/usr/bin/env bash
# Production-path dispatch wrapper: run one AGENT session on an ALREADY-LEASED
# work item, in an isolated per-run worktree, under a mechanical per-run bound
# (dollar budget cap + hard timeout), then record a joinable OTLP artifact trail and a
# WP3 return-accounting record. The inner run opens a PR and STOPS — it never
# merges and never closes the issue (pre-promotion C2 policy: the human merges).
#
# Contract change (autonomy-ignition Phase 1): the CALLER holds the lease.
# drain-next.sh claims the item via the tracker seam and passes the item, its
# governance-sourced work class, and the per-run id in here; this wrapper does
# NOT claim (a second claim would double-lease).
#
# Standing session telemetry (exporters/endpoint) comes from the machine's own
# settings env; the wrapper injects only the per-item resource attributes and the
# trace context, per the #351 emission-source decision.
#
# The inner run's task is the issue itself (it reads the body via `gh issue view`);
# this wrapper authors the standard C2 PR-flow prompt, so the caller passes only
# the issue and the per-run metadata.
#
# Usage:
#   dispatch-item.sh <issue-number> \
#     --work-class <C1..C5> --run-id <run-id> [--fire-kind manual|scheduled]
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drain-common.sh"

issue="${1:-}"
[[ -n "$issue" ]] || {
  echo "usage: dispatch-item.sh <issue-number> --work-class <C1..C5> --run-id <id> [--fire-kind manual|scheduled]" >&2
  exit 2
}
shift

work_class="" run_id="" fire_kind="manual"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-class)
      work_class="${2:?--work-class needs a value}"
      shift 2
      ;;
    --run-id)
      run_id="${2:?--run-id needs a value}"
      shift 2
      ;;
    --fire-kind)
      fire_kind="${2:?--fire-kind needs a value}"
      shift 2
      ;;
    *)
      echo "dispatch-item.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
[[ -n "$work_class" && -n "$run_id" ]] || {
  echo "dispatch-item.sh: --work-class and --run-id are required" >&2
  exit 2
}

owner_repo="$(drain_owner_repo)"
item_url="$(drain_item_url "$owner_repo" "$issue")"
branch="${DRAIN_BRANCH_PREFIX}/${issue}/${run_id}"
worktree="${DRAIN_WORKTREE_ROOT}/${run_id}"

mkdir -p "$DRAIN_ARTIFACT_DIR" "$DRAIN_WORKTREE_ROOT"

# Fail closed if only a non-coreutils `timeout` (e.g. Windows timeout.exe, which
# pauses rather than killing) is resolvable: an unbounded inner run violates the
# per-run mechanical bound this rework exists to add.
timeout_bin="$(drain_timeout_bin)"
[[ -n "$timeout_bin" ]] || {
  echo "dispatch-item.sh: no GNU coreutils 'timeout' found; refusing to run unbounded" >&2
  exit 3
}
inner_timeout_secs="${DRAIN_INNER_TIMEOUT_SECS:-3300}" # under the hourly cadence
# Mechanical spend bound on the inner invocation. The plan named a per-turn cap
# flag that does not exist in this CLI (verified against `claude --help`);
# `--max-budget-usd` is the enforced per-invocation bound. Default is a
# conservative placeholder for a C2 Sonnet task — operator tunes at Phase 2.
inner_max_budget_usd="${DRAIN_INNER_MAX_BUDGET_USD:-5.00}"

drain_record_run "$(jq -cn --arg r "$run_id" --arg i "$issue" --arg u "$item_url" \
  --arg b "$branch" --arg w "$worktree" --arg wc "$work_class" --arg fk "$fire_kind" \
  --arg ts "$(drain_iso_now)" \
  '{run_id:$r, issue:($i|tonumber), item_url:$u, branch:$b, worktree:$w,
    work_class:$wc, fire_kind:$fk, status:"dispatched", ts:$ts}')"

# Disposable per-run worktree for the inner session. Removed on normal exit; an
# orphan left by a killed parent is cleaned by drain-next.sh's reconcile preamble.
cleanup_worktree() {
  [[ -d "$worktree" ]] || return 0
  git -C "$DRAIN_REPO_ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || true
}
trap cleanup_worktree EXIT
git -C "$DRAIN_REPO_ROOT" worktree add -b "$branch" "$worktree" HEAD >/dev/null

# Contract-authored wrapper span + trace context; run_id is the join discriminator.
trace_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
span_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
# Portable epoch-nanos: `date +%s%N` is GNU-only and yields silent garbage where
# %N is unsupported. The join (verify-join.sh) never reads these times, so
# second-resolution zero-padded to nanos is the simplest correct OTLP form.
start_ns="$(date +%s)000000000"
export TRACEPARENT="00-${trace_id}-${span_id}-01"
export OTEL_RESOURCE_ATTRIBUTES="autonomy.work_item.url=${item_url},cicd.pipeline.run.id=${run_id},signal.work_class=${work_class}"

# Evidence surfaces the inner agent must never write (wrapper-authored only).
otel_store="$(drain_otel_store 2>/dev/null || true)"

read -r -d '' inner_prompt <<PROMPT || true
You are an autonomous ${work_class} mechanical-maintenance worker resolving GitHub
issue #${issue} (${item_url}) in repository ${owner_repo}. You are running in an
isolated git worktree at ${worktree}, already checked out on the pre-created work
branch '${branch}'. Do exactly the following, then STOP:

1. Read the issue: gh issue view ${issue}
2. Implement the minimal, mechanical change the issue asks for. This is ${work_class}
   (deterministic, trivially reversible) work — stay strictly within that scope.
3. Commit on the CURRENT branch '${branch}' (do not switch or create other branches).
4. Push the branch: git push -u origin ${branch}
5. Open a pull request referencing issue #${issue}: gh pr create --head ${branch} --fill

FORBIDDEN: do NOT merge the PR; do NOT close the issue; do NOT push to the default
branch; do NOT modify .claude/autonomy/** or change any issue labels; do NOT write
to the evidence surfaces .artifacts/** or the OTel session store (${otel_store:-the
local OTel session store directory}) — those are wrapper-authored only. Open the PR
and stop.
PROMPT

set +e
(cd "$worktree" && "$timeout_bin" "$inner_timeout_secs" \
  claude -p "$inner_prompt" --model sonnet --max-budget-usd "$inner_max_budget_usd")
agent_rc=$?
set -e
end_ns="$(date +%s%N)"

cat >>"$DRAIN_PIPELINE" <<JSON
{"resourceSpans":[{"schemaUrl":"https://opentelemetry.io/schemas/1.43.0","resource":{"attributes":[]},"scopeSpans":[{"scope":{"name":"autonomy-demo-dispatch"},"spans":[{"traceId":"${trace_id}","spanId":"${span_id}","name":"autonomy-dispatch","kind":2,"startTimeUnixNano":"${start_ns}","endTimeUnixNano":"${end_ns}","attributes":[{"key":"cicd.pipeline.run.id","value":{"stringValue":"${run_id}"}},{"key":"autonomy.work_item.url","value":{"stringValue":"${item_url}"}},{"key":"signal.work_class","value":{"stringValue":"${work_class}"}},{"key":"autonomy.fire_kind","value":{"stringValue":"${fire_kind}"}}]}]}]}]}
JSON

if [[ "$agent_rc" -eq 124 ]]; then
  echo "inner session exceeded ${inner_timeout_secs}s and was killed; item stays leased, no return record" >&2
fi
if [[ "$agent_rc" -ne 0 ]]; then
  drain_record_run "$(jq -cn --arg r "$run_id" --arg i "$issue" --arg b "$branch" \
    --argjson rc "$agent_rc" --arg ts "$(drain_iso_now)" \
    '{run_id:$r, issue:($i|tonumber), branch:$b, status:"failed", agent_rc:$rc, ts:$ts}')"
  echo "agent session failed (rc=$agent_rc); item stays leased, no close record written" >&2
  exit "$agent_rc"
fi

# Discover the PR the inner run opened (deterministic off the branch name).
pr_url="$(gh pr list --repo "$owner_repo" --head "$branch" --state all \
  --json url --jq '.[0].url // empty')"

# WP3 return-accounting record (marker-keyed, create-only). No issue close, no
# merge — the human merges during the C2 accumulation window. The attested-to
# owner is resolved at runtime (binding producer_identity, else `gh api user`),
# never a script literal.
operator_login="$(drain_operator_login)"
if ! gh issue view "$issue" --json comments --jq '.comments[].body' | grep -qF 'autonomy:return-accounting:v1'; then
  gh issue comment "$issue" --body-file - <<EOF
<!-- autonomy:return-accounting:v1 -->

\`\`\`json
{
  "schema_version": "1",
  "work_item_url": "${item_url}",
  "run_id": "${run_id}",
  "work_class": "${work_class}",
  "fire_kind": "${fire_kind}",
  "pr_url": "${pr_url}",
  "attested": false,
  "attestation_request": "${item_url}",
  "attestation_owner": { "identity": "${operator_login}", "role": "requester" }
}
\`\`\`

@${operator_login} This item was worked autonomously; a PR is open awaiting your review and merge. Two questions:

1. **Would you have spent engineering effort on this anyway?** — \`yes\` / \`no\` / \`partial\`
2. **What would it have cost in manual eng-hours?** — \`<1h\` / \`1-4h\` / \`4h-1d\` / \`1d-1w\` / \`1w-1mo\` / \`>1mo\`

Reply to this comment with your answers (e.g. \`partial, 1-4h\`) — or start a new comment with \`attest:\` — or skip; a skip leaves the record unattested.
EOF
fi

drain_record_run "$(jq -cn --arg r "$run_id" --arg i "$issue" --arg b "$branch" \
  --arg p "$pr_url" --arg ts "$(drain_iso_now)" \
  '{run_id:$r, issue:($i|tonumber), branch:$b, pr_url:$p, status:"complete", ts:$ts}')"

echo "trace_id=${trace_id}"
echo "run_id=${run_id}"
echo "artifact=${DRAIN_PIPELINE}"
echo "item=${item_url}"
echo "pr=${pr_url:-<none-found>}"
