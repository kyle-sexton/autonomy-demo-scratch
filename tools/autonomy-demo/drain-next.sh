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
# dedup reconcile filings (adapter obligation 2: idempotent, identity-keyed). The
# `tr -d '\r'` strips the carriage return jq.exe appends per line on Windows;
# without it every title ends in CR and the `grep -qxF` dedup below never matches,
# re-filing the same reconcile item on every hourly fire.
drain_open_reconcile_titles() {
  "$ADAPTER_DIR/list-items.sh" --state open 2>/dev/null \
    | jq -r '.items[]?.title' 2>/dev/null | tr -d '\r' || true
}

# drain_file_reconcile_item <kind> <run_id> <issue-or-dash> <detail> — file one
# deduped, human-gated tracker item. Title carries the (kind,run,issue) identity.
drain_file_reconcile_item() {
  local kind="$1" rid="$2" ref="$3" detail="$4"
  local title
  title="$(drain_reconcile_title "$kind" "$rid" "$ref")"
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

  # 2. Merged-but-open C2 items (double-drain hazard). Once a human merges a drain
  # PR, the issue should be closed; while it stays OPEN and C2-labelled, clearing
  # its assignee would make it claimable again (a re-drain of already-shipped work).
  # The drain NEVER closes issues/PRs — it files a human-gated reconcile item. Keyed
  # on the merged PR's run_id (embedded in the head branch), so the title is stable
  # and drain_file_reconcile_item dedups it idempotently across hourly fires.
  # gh reads here are load-bearing for the guard; a read failure WARNs loudly and
  # skips the block (never a silent no-op that would hide the double-drain hazard).
  local owner_repo merged_raw open_raw
  owner_repo="$(drain_owner_repo 2>/dev/null || true)"
  if [[ -z "$owner_repo" ]]; then
    echo "drain-next: WARN reconcile could not resolve owner/repo; skipping merged-but-open check" >&2
  elif ! merged_raw="$(gh pr list --repo "$owner_repo" \
    --search "head:${DRAIN_BRANCH_PREFIX}/ is:merged" \
    --json number,headRefName --limit 200 2>/dev/null)"; then
    echo "drain-next: WARN reconcile could not list merged drain PRs; skipping merged-but-open check" >&2
  elif ! open_raw="$("$ADAPTER_DIR/list-items.sh" --state open 2>/dev/null)"; then
    echo "drain-next: WARN reconcile could not list open items; skipping merged-but-open check" >&2
  else
    local merged_count merged_map open_c2 existing_titles flags
    # Truncation tell: server-side search narrows to drain PRs, so hitting the cap
    # is unlikely, but a full page means the view may be incomplete.
    merged_count="$(printf '%s' "$merged_raw" | jq 'length' 2>/dev/null || echo 0)"
    [[ "$merged_count" -ge 200 ]] \
      && echo "drain-next: WARN merged drain-PR list hit the 200 cap; merged-but-open check may be incomplete" >&2
    # Merged drain PRs -> "<issue>\t<pr_number>\t<run_id>" (run_id = branch segment).
    # The startswith filter re-verifies the server-side head: match client-side.
    merged_map="$(printf '%s' "$merged_raw" | jq -r --arg pfx "${DRAIN_BRANCH_PREFIX}/" '
        .[] | select(.headRefName | startswith($pfx))
        | (.headRefName | ltrimstr($pfx) | split("/")) as $seg
        | [$seg[0], (.number | tostring), $seg[1]] | @tsv' | tr -d '\r')"
    # Open items still carrying the C2 label (issue numbers, one per line).
    open_c2="$(printf '%s' "$open_raw" | jq -r --arg lbl "$label" \
      '.items[]? | select(.labels | index($lbl)) | (.url | split("/") | last)' | tr -d '\r')"
    existing_titles="$(drain_open_reconcile_titles)"
    # Pure decision (testable off fixtures): which OPEN+C2 issues have a merged
    # drain PR and no reconcile item already filed.
    flags="$(printf '%s\n' "$merged_map" | drain_merged_but_open_flags "$open_c2" "$existing_titles")"
    local m_issue pr_num run_from_branch detail
    while IFS=$'\t' read -r m_issue pr_num run_from_branch; do
      [[ -n "$m_issue" ]] || continue
      detail="issue #${m_issue} is OPEN and ${label}-labelled but its drain PR #${pr_num} is already MERGED; close the issue by hand (an open merged item can be re-claimed if its assignee is cleared)"
      if [[ "$dry" == "true" ]]; then
        echo "reconcile(dry): item #${m_issue} merged-but-open (PR #${pr_num}, run ${run_from_branch:-?}) — would file reconcile item"
      else
        drain_file_reconcile_item "merged-but-open" "${run_from_branch:-unknown}" "$m_issue" "$detail"
      fi
    done <<<"$flags"
  fi

  # 3. Detections over this pipeline's own prior runs (run-state, last status
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

    # 3a. Stranded lease: item still open under a dead run of ours.
    local istate
    istate="$(gh issue view "$pissue" --repo "$(drain_owner_repo)" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [[ "$istate" == "OPEN" ]]; then
      drain_file_reconcile_item "stranded-lease" "$prid" "$pissue" \
        "item still OPEN after a dead drain run held its lease (session_id=$prid); verify the lease and reclaim or reassign by hand"
    fi

    # 3b. Branch without PR, and 3c. PR without an evidence row.
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
mapfile -t candidates < <(printf '%s\n' "$items_json" | drain_select_candidates "$label")

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
