#!/usr/bin/env bash
# Hourly drain entrypoint (autonomy-ignition Phase 1). One firing:
#
#   (a) reconcile preamble — remove orphaned run worktrees this pipeline left
#       behind; DETECT (never break) stranded leases from this pipeline's own
#       dead runs, work branches without PRs, and PRs without an evidence row,
#       filing a human-gated tracker item via the seam for anything it cannot
#       safely auto-fix;
#   (b) claim the first eligible C2-labelled open item via the tracker seam
#       (2h lease TTL, per-run --session-id);
#   (c) dispatch the claimed item (open PR, stop — never merge/close);
#   (d) print `no-work` and exit 0 on an empty queue (a valid fire).
#
# `--dry-run` performs NO side effects: it prints what it WOULD claim (or
# `no-work`) after a read-only reconcile report.
#
# Usage: drain-next.sh [--dry-run] [--fire-kind manual|scheduled] [--session-id <id>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

ADAPTER_DIR="${DRAIN_REPO_ROOT}/tools/work-item-tracker/adapters/github"

dry_run=false
fire_kind="${DRAIN_FIRE_KIND:-manual}"
session_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --fire-kind)
      fire_kind="${2:?--fire-kind needs a value}"
      shift 2
      ;;
    --session-id)
      session_id="${2:?--session-id needs a value}"
      shift 2
      ;;
    *)
      echo "drain-next.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

run_id="${session_id:-$(drain_new_run_id "$fire_kind")}"
label="$(drain_c2_label)"
work_class="$(drain_class_from_label "$label")"
# No unconditional mkdir here: --dry-run must not touch the filesystem. The
# artifact dir is created lazily by drain_record_run / dispatch on the live path.

# --- reconcile helpers ------------------------------------------------------

# drain_open_reconcile_titles — titles of currently-open tracker items, used to
# dedup reconcile filings (adapter obligation 2: idempotent, identity-keyed).
drain_open_reconcile_titles() {
  "$ADAPTER_DIR/list-items.sh" --state open 2>/dev/null \
    | jq -r '.items[]?.title' 2>/dev/null || true
}

# drain_file_reconcile_item <kind> <run_id> <issue-or-dash> <detail> — file one
# deduped, human-gated tracker item. Title carries the (kind,run,issue) identity.
drain_file_reconcile_item() {
  local kind="$1" rid="$2" ref="$3" detail="$4"
  local title="[drain-reconcile] ${kind}: run ${rid} item #${ref}"
  if drain_open_reconcile_titles | grep -qxF "$title"; then
    return 0
  fi
  local body
  body="$(printf 'Automated drain reconcile finding (needs human action).\n\n- kind: %s\n- run_id: %s\n- item: #%s\n- detail: %s\n\nThe drain never breaks leases or force-fixes this class of state; a human resolves it.' \
    "$kind" "$rid" "$ref" "$detail")"
  "$ADAPTER_DIR/create-item.sh" --title "$title" --body "$body" >/dev/null \
    || echo "drain-next: WARN could not file reconcile item '$title'" >&2
}

# drain_reconcile <run_id> <dry_run> — the preamble. Best-effort: a transient
# read failure warns and continues rather than blocking the day's fire.
drain_reconcile() {
  local rid="$1" dry="$2"

  # 1. Orphaned run worktrees (safe local auto-fix). Anything under the run
  # worktree root that is not the current run is an orphan (runs never overlap).
  # `worktree prune` is a git write, so it is gated out of dry-run.
  if [[ "$dry" != "true" ]]; then
    git -C "$DRAIN_REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  fi
  if [[ -d "$DRAIN_WORKTREE_ROOT" ]]; then
    local wt
    for wt in "$DRAIN_WORKTREE_ROOT"/*; do
      [[ -d "$wt" ]] || continue
      [[ "$(basename "$wt")" == "$rid" ]] && continue
      if [[ "$dry" == "true" ]]; then
        echo "reconcile(dry): would remove orphan worktree $wt"
      else
        git -C "$DRAIN_REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 \
          || rm -rf "$wt"
        echo "reconcile: removed orphan worktree $wt"
      fi
    done
  fi

  # 2. Detections over this pipeline's own prior runs (run-state, last status
  # per run_id). Dry-run reports; a live run files deduped human-gated items.
  [[ -f "$DRAIN_RUN_STATE" ]] || return 0
  local latest
  # Append-only flatten: later records override earlier ones per run_id
  # (new + accumulated with new winning), preserving fields a terminal record omits.
  latest="$(jq -sc '
    reduce .[] as $r ({}; .[$r.run_id] = ((.[$r.run_id] // {}) + $r))
    | [.[]]' "$DRAIN_RUN_STATE" 2>/dev/null || printf '[]')"

  local incomplete
  incomplete="$(printf '%s' "$latest" | jq -c --arg cur "$rid" '
    .[] | select(.run_id != $cur)
    | select((.status // "") as $s | ($s != "complete" and $s != "failed-reported"))')"

  local rec
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    local prid pissue pbranch
    prid="$(jq -r '.run_id' <<<"$rec")"
    pissue="$(jq -r '.issue // "-"' <<<"$rec")"
    pbranch="$(jq -r '.branch // empty' <<<"$rec")"

    if [[ "$dry" == "true" ]]; then
      echo "reconcile(dry): prior run $prid (item #$pissue) left status=$(jq -r '.status // "?"' <<<"$rec") — would inspect lease/branch/PR/evidence"
      continue
    fi

    # 2a. Stranded lease: item still open under a dead run of ours.
    local istate
    istate="$(gh issue view "$pissue" --repo "$(drain_owner_repo)" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [[ "$istate" == "OPEN" ]]; then
      drain_file_reconcile_item "stranded-lease" "$prid" "$pissue" \
        "item still OPEN after a dead drain run held its lease (session_id=$prid); verify the lease and reclaim or reassign by hand"
    fi

    # 2b. Branch without PR, and 2c. PR without an evidence row.
    if [[ -n "$pbranch" ]]; then
      local pr_url
      pr_url="$(gh pr list --repo "$(drain_owner_repo)" --head "$pbranch" --state all \
        --json url --jq '.[0].url // empty' 2>/dev/null || true)"
      if [[ -z "$pr_url" ]]; then
        if gh api "repos/$(drain_owner_repo)/git/refs/heads/$pbranch" >/dev/null 2>&1; then
          drain_file_reconcile_item "branch-without-pr" "$prid" "$pissue" \
            "branch '$pbranch' exists on the remote with no open/closed PR; open a PR or delete the branch"
        fi
      elif [[ -f "$DRAIN_PIPELINE" ]] && ! grep -qF "\"$prid\"" "$DRAIN_PIPELINE"; then
        drain_file_reconcile_item "pr-without-evidence" "$prid" "$pissue" \
          "PR $pr_url exists but no pipeline evidence row carries run_id $prid; the wrapper span was not recorded"
      fi
    fi
  done <<<"$incomplete"
}

# --- (a) reconcile ----------------------------------------------------------
drain_reconcile "$run_id" "$dry_run" || echo "drain-next: WARN reconcile hit an error; continuing" >&2

# --- (b) candidate selection via the tracker seam ---------------------------
items_json="$("$ADAPTER_DIR/list-items.sh" --state open)"
mapfile -t candidates < <(printf '%s\n' "$items_json" | jq -r --arg lbl "$label" '
  .items
  | map(select((.labels | index($lbl)) and .blocked_by_count == 0 and (.assignees | length == 0)))
  | sort_by(.url | split("/") | last | tonumber)
  | .[] | [.id, .url] | @tsv')

if [[ "${#candidates[@]}" -eq 0 ]]; then
  echo "no-work"
  exit 0
fi

if [[ "$dry_run" == "true" ]]; then
  IFS=$'\t' read -r _dry_id dry_url <<<"${candidates[0]}"
  echo "would-claim ${dry_url} (run_id ${run_id}, work_class ${work_class})"
  exit 0
fi

# --- claim the first eligible item that is not already leased ----------------
claimed_id="" claimed_url="" claimed_num=""
for row in "${candidates[@]}"; do
  IFS=$'\t' read -r cid curl <<<"$row"
  set +e
  "$ADAPTER_DIR/claim.sh" "$cid" --ttl-hours 2 --session-id "$run_id" >/dev/null
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    claimed_id="$cid"
    claimed_url="$curl"
    claimed_num="${cid##*#}"
    break
  fi
  # EX_CONFLICT (7): already leased by someone else — try the next candidate.
  # Any other code is a real seam failure; surface it.
  if [[ "$rc" -ne 7 ]]; then
    echo "drain-next: claim failed (rc=$rc) on $cid" >&2
    exit "$rc"
  fi
done

if [[ -z "$claimed_id" ]]; then
  echo "no-work" # every eligible item is already leased; next fire retries
  exit 0
fi

drain_record_run "$(jq -cn --arg r "$run_id" --arg i "$claimed_num" --arg u "$claimed_url" \
  --arg ts "$(drain_iso_now)" \
  '{run_id:$r, issue:($i|tonumber), item_url:$u, status:"claimed", ts:$ts}')"

# --- (c) dispatch -----------------------------------------------------------
set +e
"$SCRIPT_DIR/dispatch-item.sh" "$claimed_num" \
  --work-class "$work_class" --run-id "$run_id" --fire-kind "$fire_kind"
drc=$?
set -e
if [[ "$drc" -ne 0 ]]; then
  drain_file_reconcile_item "dispatch-failure" "$run_id" "$claimed_num" \
    "dispatch-item.sh exited $drc for #$claimed_num; item stays leased for human triage (reconcile-first, no auto-retry)"
  drain_record_run "$(jq -cn --arg r "$run_id" --arg i "$claimed_num" --argjson rc "$drc" \
    --arg ts "$(drain_iso_now)" \
    '{run_id:$r, issue:($i|tonumber), status:"failed-reported", dispatch_rc:$rc, ts:$ts}')"
  echo "drain-next: dispatch failed (rc=$drc); filed human-gated tracker item" >&2
  exit "$drc"
fi

echo "claimed ${claimed_url}"
