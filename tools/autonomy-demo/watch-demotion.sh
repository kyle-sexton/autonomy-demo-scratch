#!/usr/bin/env bash
# watch-demotion.sh — the mechanical post-merge net (repo issue #41): a deterministic,
# zero-model-token check that every DRAINED, MERGED PR still stands. It replaces ad-hoc
# main-thread verification and is a REQUIRED precondition before any autonomy promotion.
# Read-only against GitHub and git; its ONLY write is append-only demotion events.
#
# For each complete drain run (drain-runs.jsonl, last-status-per-run_id) whose PR is
# MERGED, it runs two independent checks over the merge and, on any contrary signal,
# appends a demotion event and exits non-zero.
#
# Check A — post-merge gate. Asserts the merge carries a PASSING deterministic-gate.
#   GATE-ATTACHMENT / DATA LIMITATION: gate.yml triggers `on: pull_request` ONLY, so the
#   deterministic-gate check-run attaches to the PR HEAD SHA, never to the squash-merge
#   commit on main. There is NO push-triggered gate on main today, so a TRUE post-merge
#   (main-tip) gate signal — one that would catch a regression introduced by the squash
#   commit's interaction with other merges — DOES NOT EXIST yet (verified 2026-07-22: all
#   merged drain PRs carry deterministic-gate=success on the PR head SHA and NO check-run
#   on the squash commit). This script implements the strongest signal the current data
#   supports and is forward-compatible: it queries the gate conclusion on the MERGE commit
#   first (the genuine main-tip signal; today always absent) and falls back to the PR HEAD
#   SHA's gate conclusion (the pre-merge gate that authorized the merge) ONLY when the
#   merge commit carries no gate check-run. The day gate.yml gains `on: push: branches:
#   [main]`, the merge-commit check-run appears and is used automatically, no code change.
#   Verdict (drain_gate_verdict): success => clean; a non-success conclusion OR no gate
#   check-run at all on the merged PR => `gate-regression` event; an unclassifiable
#   conclusion or an unreachable check-run API => fail-closed abort (never reads as clean).
#
# Check B — revert scan. origin/main history AFTER the merge carrying a commit that
#   reverts merge_sha ("This reverts commit <sha>") => `revert` event. Reuses
#   drain_revert_sha (the same detector predicate-c2.sh / verify-join.sh use); origin is
#   fetched ONCE up front and an un-refreshable / unreadable range fails closed.
#
# Idempotent: events append to demotion-events.jsonl keyed on (kind, merge_sha); a re-run
# never duplicates an already-recorded event, but a still-standing contrary condition is
# re-DETECTED and still forces a non-zero exit (a watcher that exits 0 while a revert sits
# in main would be a false clean).
#
# Exit codes:
#   0  clean       — no contrary event detected THIS run (all-clear line reports counts)
#   1  demotion    — one or more contrary events detected this run (loud one-line summary)
#   2  usage
#   3  fail-closed — unreachable API / unreadable git range / unparseable evidence; NEVER
#                    reads as clean (evidence completeness is required for a promotion net)
#
# Usage: watch-demotion.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

readonly EXIT_DEMOTION=1
readonly EXIT_USAGE=2
readonly EXIT_FAILCLOSED=3

[[ $# -eq 0 ]] || {
  echo "usage: watch-demotion.sh" >&2
  exit "$EXIT_USAGE"
}

abort_failclosed() {
  echo "watch-demotion: FATAL $1 — aborting (evidence incomplete; a post-merge net must never read as clean)" >&2
  exit "$EXIT_FAILCLOSED"
}

owner_repo="$(drain_owner_repo)"
mkdir -p "$DRAIN_ARTIFACT_DIR"
events_file="$DRAIN_DEMOTION_EVENTS"

# Enumerate complete drain runs. Malformed evidence FAILS CLOSED (contrast predicate-c2.sh,
# which fail-softs to "not eligible"): a watcher that cannot parse its own evidence must
# abort, never silently report all-clear.
complete_rows="$(drain_complete_runs "$DRAIN_RUN_STATE")" \
  || abort_failclosed "drain-runs.jsonl unparseable ($DRAIN_RUN_STATE)"
n="$(jq 'length' <<<"$complete_rows")"

# Check B reads origin/main; refresh it ONCE (not per row) and fail closed on an
# un-refreshable origin — stale/unknown revert state must not read as clean. Only when
# there is work to check.
if [[ "$n" -gt 0 ]]; then
  git -C "$DRAIN_REPO_ROOT" fetch --quiet origin 2>/dev/null \
    || abort_failclosed "could not fetch origin (revert status undeterminable)"
fi

merges_checked=0
events_this_run=0

# record_event <kind> <merge_sha> <pr_url> <run_id> <detail>. Counts every DETECTED
# contrary event (so a still-standing but already-recorded event still forces non-zero),
# then appends the row only when (kind, merge_sha) is not already logged (idempotent).
record_event() {
  local kind="$1" merge_sha="$2" pr_url="$3" run_id="$4" detail="$5" rc
  events_this_run=$((events_this_run + 1))
  if drain_demotion_already_recorded "$kind" "$merge_sha" "$events_file"; then
    echo "watch-demotion: ${kind} for merge ${merge_sha} already recorded — not duplicating row" >&2
    return 0
  else
    rc=$?
    # rc 1 = not recorded (append below); rc 3 = events file present but unparseable —
    # fail closed, never append blindly (that would defeat the dedup guarantee).
    [[ "$rc" -eq 1 ]] \
      || abort_failclosed "demotion-events.jsonl unparseable ($events_file); idempotency undeterminable for ${kind}/${merge_sha}"
  fi
  jq -cn --arg da "$(drain_iso_now)" --arg k "$kind" --arg ms "$merge_sha" \
    --arg pr "$pr_url" --arg rid "$run_id" --arg d "$detail" \
    '{detected_at: $da, kind: $k, merge_sha: $ms, pr_url: $pr, run_id: $rid, detail: $d}' \
    >>"$events_file"
}

i=0
while [[ "$i" -lt "$n" ]]; do
  row="$(jq -c ".[$i]" <<<"$complete_rows")"
  i=$((i + 1))
  pr_url="$(jq -r '.pr_url // ""' <<<"$row" | tr -d '\r')"
  run_id="$(jq -r '.run_id // ""' <<<"$row" | tr -d '\r')"
  # A complete run should carry a pr_url; without one there is no merge to watch.
  [[ -n "$pr_url" ]] || continue

  merge_state="$(drain_pr_merge_state "$pr_url")" \
    || abort_failclosed "gh pr view failed for ${pr_url} (merge state undeterminable)"
  IFS=$'\t' read -r head_sha merge_sha merged_at <<<"$merge_state"

  # Post-merge net: only MERGED PRs are in scope. An unmerged complete run is a legitimate
  # not-yet state (skip), NOT an error — drain_pr_merge_state distinguishes it (empty
  # merge_sha/merged_at, rc 0) from an undeterminable lookup (rc != 0, aborted above).
  [[ -n "$merged_at" && -n "$merge_sha" ]] || continue
  merges_checked=$((merges_checked + 1))

  # --- Check A: post-merge gate --------------------------------------------
  # Merge-commit gate first (genuine main-tip signal; today absent), else PR-head gate.
  # Fall back ONLY on an EMPTY merge-commit result: a present-but-non-success merge-commit
  # conclusion is authoritative and must NOT be masked by the pre-merge head gate.
  gate_sha="$merge_sha" gate_src="merge-commit"
  gate_conc="$(drain_gate_conclusion "$owner_repo" "$merge_sha")" \
    || abort_failclosed "check-run API unreachable for merge ${merge_sha} (${pr_url})"
  if [[ -z "$gate_conc" ]]; then
    [[ -n "$head_sha" ]] \
      || abort_failclosed "no merge-commit gate and no PR head SHA to fall back on (${pr_url})"
    gate_sha="$head_sha" gate_src="pr-head"
    gate_conc="$(drain_gate_conclusion "$owner_repo" "$head_sha")" \
      || abort_failclosed "check-run API unreachable for PR head ${head_sha} (${pr_url})"
  fi
  case "$(drain_gate_verdict "$gate_conc")" in
    clean) : ;;
    contrary)
      record_event "gate-regression" "$merge_sha" "$pr_url" "$run_id" \
        "gate on ${gate_src} ${gate_sha:0:12} is '${gate_conc:-<none>}' (expected success)"
      ;;
    *)
      abort_failclosed "gate conclusion '${gate_conc}' on ${gate_src} ${gate_sha} unclassifiable (${pr_url})"
      ;;
  esac

  # --- Check B: revert scan ------------------------------------------------
  if ! rev_sha="$(drain_revert_sha "$DRAIN_REPO_ROOT" "$merge_sha" "origin/main")"; then
    abort_failclosed "revert lookup failed for merge ${merge_sha} (origin/main range unreadable) (${pr_url})"
  fi
  if [[ -n "$rev_sha" ]]; then
    record_event "revert" "$merge_sha" "$pr_url" "$run_id" \
      "origin/main commit ${rev_sha:0:12} reverts merge ${merge_sha:0:12}"
  fi
done

# Historical total: every event ever logged (this run appended none when events_this_run
# is 0, so this counts prior events only on the all-clear path). grep -c counts lines
# robustly whether or not the file ends in a newline; never a raw byte count.
historical=0
[[ -f "$events_file" ]] && historical="$(grep -c '' "$events_file" 2>/dev/null || printf 0)"

if [[ "$events_this_run" -gt 0 ]]; then
  echo "watch-demotion: DEMOTION — ${events_this_run} contrary event(s) across ${merges_checked} merge(s) checked; see ${events_file}" >&2
  exit "$EXIT_DEMOTION"
fi
echo "watch-demotion: all clear — ${merges_checked} merge(s) checked, 0 contrary this run, ${historical} event(s) recorded historically"
exit 0
