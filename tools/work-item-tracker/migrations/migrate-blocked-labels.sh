#!/usr/bin/env bash
# migrate-blocked-labels.sh — retire the `status: blocked` / `status: claimed` labels
# to the two native status models: blocked = native blocked-by edge, claim = assignee
# + lease comment (docs/conventions/issue-labels.md "Two status models that are not
# labels"). Runbook, the prepared protocol flip, and the prepared doc edits, plus the
# locked governance references: README.md in this directory.
#
# --dry-run is the DEFAULT and is strictly read-only: it emits the full proposed
# migration set for owner review and mutates nothing. --apply performs the live
# migration and is a GATED, human-run step. --verify runs the post-migration sanity
# checks (read-only).
#
# Idempotent: apply skips edges/labels already in the target state, and never disrupts
# in-flight claimed work (an issue with an open PR or an active lease comment keeps its
# claim; label deletion is refused while any issue still carries the label).
set -uo pipefail

# ---------------------------------------------------------------------------
# Constants — the live label spellings (verified against the tracker: both the
# status and wayfind axes use colon-SPACE). Overridable via flags so a spelling
# drift never silently no-ops the migration.
# ---------------------------------------------------------------------------
LABEL_BLOCKED="status: blocked"
LABEL_CLAIMED="status: claimed"
REIFY_LABEL="wayfind: task" # external blockers reified as task items (Brief)
DEFAULT_LIMIT=200
REIFY_EXTERNAL="false" # opt-in: convert vetted external blockers to wayfind: task items

# Structural markers the phase-entry check requires to be present (charting created
# them 2026-07-11). Provisioned by the github-iac label-as-code program — IaC is the
# sole label writer (see README.md), so a MISSING marker fails the check rather than
# being created ad hoc.
REQUIRED_MARKERS=(
  "work-map" "needs-human"
  "wayfind: research" "wayfind: interview" "wayfind: design"
  "wayfind: prototype" "wayfind: task"
)

readonly EX_OK=0 EX_INTERNAL=1 EX_USAGE=2 EX_PROVIDER=8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SEAM="$SCRIPT_DIR/../work-item-tracker.sh"
readonly GH_BOT="$SCRIPT_DIR/../../github-auth/gh-bot.sh"

# ===========================================================================
# Pure logic (no I/O) — unit-tested by migrate-blocked-labels.test.sh.
# ===========================================================================

# mbl_parse_depends_on — read an issue body on stdin, emit one blocker token per line:
#   internal:<number>   a `#<n>` reference inside a Depends-on / blocked-on clause
#   external:<text>     a Depends-on clause naming a non-issue blocker (reify target)
# Only refs in the dependency CLAUSE are taken — the run of issue refs (comma/"and"
# separated) immediately after the trigger, stopping at the first prose token. This
# excludes same-line map refs (a "Part of map …" note) and prior-dep notes (a "Prior
# dep … closed" aside). Internal refs are de-duplicated in first-seen order.
mbl_parse_depends_on() {
  local body lines line rest tok clean ext got_ref
  body="$(cat)"
  lines="$(printf '%s\n' "$body" \
    | grep -iE 'depends[[:space:]]+on|blocked[[:space:]]+on|blocked[[:space:]]+by' || true)"
  [[ -z "$lines" ]] && return 0
  local -A seen=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="$(printf '%s' "$line" \
      | sed -E 's/.*([Dd]epends[[:space:]]+on|[Bb]locked[[:space:]]+(on|by))[[:space:]]*:?[[:space:]]*//')"
    got_ref=0
    local -a toks=()
    read -ra toks <<<"$rest"
    for tok in "${toks[@]}"; do
      clean="${tok//[\*_\`]/}"
      if [[ "$clean" =~ ^#([0-9]+) ]]; then
        got_ref=1
        local n="${BASH_REMATCH[1]}"
        [[ -n "${seen[$n]:-}" ]] && continue
        seen[$n]=1
        printf 'internal:%s\n' "$n"
        continue
      fi
      # Separators keep the clause open; anything else ends it.
      case "${clean//[[:punct:]]/}" in
        "" | and | plus) continue ;;
        *) break ;;
      esac
    done
    if [[ "$got_ref" -eq 0 ]]; then
      ext="$(printf '%s' "$rest" | sed -E 's/[*_`]+//g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
      [[ -n "$ext" ]] && printf 'external:%s\n' "$ext"
    fi
  done <<<"$lines"
}

# mbl_claim_state <now-epoch> — read the `--paginate --slurp` comment pages (JSON) on
# stdin, emit the current claim state: claimed | released | none. Mirrors the tracker's
# lease semantics (adapters/github: claim.sh arbitration + wit_lease_is_live; the
# per-worker textual-trail rules in docs/conventions/worker-protocol.md "Claim protocol"):
#   1. ANY live lease marker (no superseded_at, now within renewed_at + ttl_hours) is
#      claimed — checked first because a losing claim backs off by superseding its own
#      NEWER comment while an earlier lease stays live.
#   2. Otherwise the legacy textual trail is evaluated PER worker id: a claim is active
#      only while `claimed: <id>` is that id's latest lease event — a later
#      released:/unclaimed:/blocked: from the SAME id withdraws it, but ANOTHER worker's
#      withdrawal never masks a live claim (worker-protocol.md: withdrawal is same-id).
#      Any worker holding an active claim ⇒ claimed. A plain-text `work-item-lease
#      reclaimed:` note is a GLOBAL clear (reclaim.sh posts it after clearing assignees):
#      it releases every textual claim older than it, but a claim re-posted after it is
#      live again. A textual claim with no parseable worker id fails closed (its own
#      group ⇒ counted as an active claim) rather than reading as released.
#   3. No lease/claim trail at all ⇒ none.
mbl_claim_state() {
  local now_epoch="$1"
  jq -r --argjson now "$now_epoch" '
    def is_lease: .body | startswith("<!-- work-item-lease v1 ");
    def lease: .body | ltrimstr("<!-- work-item-lease v1 ") | rtrimstr(" -->")
      | (try fromjson catch {});
    def live: lease as $l
      | (($l.superseded_at // "") == "")
        and (($l.ttl_hours | type) == "number")
        and ((($l.renewed_at // "") | (try fromdateiso8601 catch null)) as $renewed
             | $renewed != null and $now < ($renewed + $l.ttl_hours * 3600));
    [.[][] | select(.body | startswith("claimed:") or startswith("released:")
                          or startswith("unclaimed:") or startswith("blocked:")
                          or startswith("work-item-lease reclaimed:")
                          or startswith("<!-- work-item-lease v1 "))] as $events
    | if ($events | any(.[]; is_lease and live)) then "claimed"
      else
        ([$events[] | select(.body | startswith("work-item-lease reclaimed:")) | .id]
         | max // -1) as $reclaimed_id
        | [$events[]
           | . as $e
           | select($e.body | test("^(claimed|released|unclaimed|blocked):"))
           | {id: $e.id,
              verb: ($e.body | capture("^(?<v>claimed|released|unclaimed|blocked):").v),
              w: (if ($e.body | test("^(?:claimed|released|unclaimed|blocked):[[:space:]]*[^[:space:]]"))
                  then ($e.body | capture("^(?:claimed|released|unclaimed|blocked):[[:space:]]*(?<w>[^[:space:]]+)").w)
                  else "#" + ($e.id | tostring) end)}]
          | (group_by(.w)
             | map(sort_by(.id) | last | select(.verb == "claimed" and .id > $reclaimed_id))
             | length) as $active_claims
        | if $active_claims > 0 then "claimed"
          elif ($events | length) > 0 then "released"
          else "none" end
      end'
}

# mbl_absence_verdict <gh-exit-code> <gh-output> <grep-pattern> — the R14/R4 sanity
# discipline: a provider/fetch failure must NEVER read as "clean". Prints the verdict
# and returns a distinct code so a caller cannot mistake ERROR for ABSENT:
#   rc != 0            -> "ERROR"   return 2  (fetch failed — check FAILS)
#   pattern present    -> "PRESENT" return 1  (label still there — check FAILS)
#   pattern absent      -> "ABSENT"  return 0  (the only clean signal)
mbl_absence_verdict() {
  local rc="$1" out="$2" pattern="$3"
  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR"
    return 2
  fi
  if grep -qF "$pattern" <<<"$out"; then
    echo "PRESENT"
    return 1
  fi
  echo "ABSENT"
  return 0
}

# ===========================================================================
# I/O helpers (gh) — writes route through the bot wrapper when present
# (docs/conventions/github-ops.md "Bot identity"); reads use bare gh.
# ===========================================================================

log() { printf '%s\n' "$*" >&2; }

gh_write() {
  if [[ -f "$GH_BOT" ]]; then
    bash "$GH_BOT" "$@"
  else
    gh "$@"
  fi
}

# mbl_require_prereqs — gh + jq present; provider reachable is proven lazily by the
# first read (which fails the sanity discipline on any non-zero exit).
mbl_require_prereqs() {
  command -v gh >/dev/null 2>&1 || {
    log "prerequisite missing: gh (GitHub CLI)"
    exit "$EX_USAGE"
  }
  command -v jq >/dev/null 2>&1 || {
    log "prerequisite missing: jq"
    exit "$EX_USAGE"
  }
}

# mbl_phase_entry_check <repo> — record which required markers exist; a MISSING marker
# FAILS (governance: IaC is the sole writer, so a gap is provisioned via a github-iac
# PR, never created here). A non-zero label fetch FAILS (never reads as "all present").
mbl_phase_entry_check() {
  local repo="$1" out rc missing=()
  out="$(gh label list -R "$repo" --limit "$LIMIT" --json name 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "phase-entry: label fetch failed (exit $rc) — cannot verify marker set; aborting"
    exit "$EX_PROVIDER"
  fi
  local m
  for m in "${REQUIRED_MARKERS[@]}"; do
    if ! jq -e --arg n "$m" 'any(.[]; .name == $n)' <<<"$out" >/dev/null; then
      missing+=("$m")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    log "phase-entry: required markers MISSING: ${missing[*]}"
    log "  provision them via a melodic-software/github-iac PR before migrating (IaC is the sole label writer — EPIC #1491)."
    exit "$EX_INTERNAL"
  fi
  log "phase-entry: all ${#REQUIRED_MARKERS[@]} required markers present."
}

# mbl_fetch_issues <repo> <label> — JSON array of issues carrying <label> (all states).
# A non-zero return propagates the fetch failure (never an empty set — R4/R14). Callers
# run this in a command substitution, where `exit` would only kill the subshell; they
# must guard with `|| exit "$EX_PROVIDER"` so a failed fetch aborts the whole run.
mbl_fetch_issues() {
  local repo="$1" label="$2" out rc
  out="$(gh issue list -R "$repo" --label "$label" --state all --limit "$LIMIT" \
    --json number,title,state,assignees,body,url 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "fetch failed for label '$label' (exit $rc) — aborting (a failed fetch is never an empty set)"
    return "$EX_PROVIDER"
  fi
  printf '%s\n' "$out"
}

# mbl_issue_in_flight <repo> <number> — 0 (in-flight) when the issue has an open linked
# PR or an active lease/claim; 1 otherwise. In-flight claims are never disrupted.
#
# Fail CLOSED (R4/R14): a provider/fetch error must never read as "idle" and let apply
# clear a live claim or retro-block active work — a failed check returns in-flight. The
# claim signal is mbl_claim_state over the full comment trail: live-lease-aware and
# newest-event-wins (an issue claimed, released, then re-claimed is in-flight; a
# reclaimed/superseded lease is not). `--slurp` merges pages so the state is computed
# across all pages, not one page.
mbl_issue_in_flight() {
  local repo="$1" number="$2" timeline comments rc open_pr lease_state
  # Open, cross-referenced PRs signal active work.
  timeline="$(gh api "repos/$repo/issues/$number/timeline" --paginate --slurp 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "  #$number in-flight check FAILED (timeline fetch exit $rc) — treating as in-flight (fail closed)"
    return 0
  fi
  open_pr="$(jq '[.[][] | select(.event == "cross-referenced" and .source.issue.pull_request != null and .source.issue.state == "open")] | length' <<<"$timeline" 2>/dev/null)"
  [[ "${open_pr:-0}" -gt 0 ]] && return 0
  # Claim state from the full comment trail; no lease trail at all → not in-flight.
  comments="$(gh api "repos/$repo/issues/$number/comments" --paginate --slurp 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "  #$number in-flight check FAILED (comments fetch exit $rc) — treating as in-flight (fail closed)"
    return 0
  fi
  if ! lease_state="$(mbl_claim_state "$EPOCHSECONDS" <<<"$comments" 2>/dev/null)"; then
    log "  #$number in-flight check FAILED (claim-state parse) — treating as in-flight (fail closed)"
    return 0
  fi
  [[ "$lease_state" == "claimed" ]] && return 0
  return 1
}

# ===========================================================================
# Migration planning — build the proposed set (read-only; used by dry-run and apply).
# ===========================================================================

# mbl_plan_blocked <repo> — for each status:blocked issue, print a plan line:
#   BLOCKED <number> EDGE internal:<n>     -> create native blocked-by edge to #<n>
#   BLOCKED <number> EXTERNAL external:<t> -> a non-issue dependency phrase; review-only
#                                             by default (prose false-positives abound),
#                                             reified to a wayfind: task only with
#                                             --reify-external
#   BLOCKED <number> SKIP-INFLIGHT         -> claimed/in-flight; never retro-block
#   BLOCKED <number> NO-BLOCKER            -> label but no parseable Depends-on (review)
mbl_plan_blocked() {
  local repo="$1" issues number body tokens tok
  issues="$(mbl_fetch_issues "$repo" "$LABEL_BLOCKED")" || exit "$EX_PROVIDER"
  local n
  n="$(jq 'length' <<<"$issues")"
  local i
  for ((i = 0; i < n; i++)); do
    number="$(jq -r ".[$i].number" <<<"$issues")"
    if mbl_issue_in_flight "$repo" "$number"; then
      printf 'BLOCKED %s SKIP-INFLIGHT\n' "$number"
      continue
    fi
    body="$(jq -r ".[$i].body // \"\"" <<<"$issues")"
    tokens="$(printf '%s' "$body" | mbl_parse_depends_on)"
    if [[ -z "$tokens" ]]; then
      printf 'BLOCKED %s NO-BLOCKER\n' "$number"
      continue
    fi
    while IFS= read -r tok; do
      [[ -z "$tok" ]] && continue
      case "$tok" in
        internal:*) printf 'BLOCKED %s EDGE %s\n' "$number" "$tok" ;;
        external:*) printf 'BLOCKED %s EXTERNAL %s\n' "$number" "$tok" ;;
        *) ;;
      esac
    done <<<"$tokens"
  done
}

# mbl_plan_claimed <repo> — for each status:claimed issue, print a plan line:
#   CLAIMED <number> CLEAR assignee=<login|none>  -> orphaned: remove the label AND clear
#                                                    the lease-less assignee (frontier.sh
#                                                    excludes any assigned issue and
#                                                    reclaim.sh never touches a lease-less
#                                                    assignment, so leaving it strands the
#                                                    issue permanently)
#   CLAIMED <number> SKIP-INFLIGHT assignee=<..>  -> active claim/open PR; leave it
mbl_plan_claimed() {
  local repo="$1" issues number assignees
  issues="$(mbl_fetch_issues "$repo" "$LABEL_CLAIMED")" || exit "$EX_PROVIDER"
  local n i
  n="$(jq 'length' <<<"$issues")"
  for ((i = 0; i < n; i++)); do
    number="$(jq -r ".[$i].number" <<<"$issues")"
    assignees="$(jq -r "[.[$i].assignees[].login] | join(\",\")" <<<"$issues")"
    [[ -z "$assignees" ]] && assignees="none"
    if mbl_issue_in_flight "$repo" "$number"; then
      printf 'CLAIMED %s SKIP-INFLIGHT assignee=%s\n' "$number" "$assignees"
    else
      printf 'CLAIMED %s CLEAR assignee=%s\n' "$number" "$assignees"
    fi
  done
}

# ===========================================================================
# Apply actions (gated) — each guards on current state for idempotency.
# ===========================================================================

mbl_issue_has_label() {
  local repo="$1" number="$2" label="$3" names
  names="$(gh issue view "$number" -R "$repo" --json labels --jq '.labels[].name' 2>/dev/null)" || return 1
  grep -qxF "$label" <<<"$names"
}

mbl_apply_edge() {
  local repo="$1" number="$2" blocker="$3"
  # Skip if the edge already exists (idempotent). Match by URL, never bare number:
  # blocked-by edges can be cross-repo, so an existing other/repo#N edge must not
  # read as the planned same-repo #N edge (which would skip creating it and let the
  # removal pass drop the label without the dependency).
  local existing
  existing="$(gh issue view "$number" -R "$repo" --json blockedBy \
    --jq "[.blockedBy.nodes[].url] | index(\"https://github.com/$repo/issues/$blocker\")" 2>/dev/null || echo null)"
  if [[ "$existing" != "null" ]]; then
    log "  #$number already blocked-by #$blocker — skip"
    return 0
  fi
  if ! bash "$SEAM" link-blocks "github:$repo#$number" --blocked-by "github:$repo#$blocker" >/dev/null; then
    log "  #$number edge creation FAILED — keeping '$LABEL_BLOCKED', review manually"
    return 1
  fi
  log "  #$number blocked-by #$blocker — edge created"
}

mbl_apply_remove_label() {
  local repo="$1" number="$2" label="$3" note="$4"
  if ! mbl_issue_has_label "$repo" "$number" "$label"; then
    log "  #$number no '$label' — skip"
    return 0
  fi
  # Neither write is checked by errexit (no `set -e`), so guard both. Remove the
  # label FIRST (the load-bearing mutation) so a retry short-circuits on the
  # absent-label check above and never re-posts a duplicate audit comment; a failed
  # removal leaves the label in place with the note unposted, so the retry is clean.
  if ! gh_write issue edit "$number" -R "$repo" --remove-label "$label" >/dev/null; then
    log "  #$number '$label' removal FAILED — label retained, review manually"
    return 1
  fi
  if ! gh_write issue comment "$number" -R "$repo" --body "$note" >/dev/null; then
    log "  #$number '$label' removed but audit comment FAILED to post — review manually"
    return 1
  fi
  log "  #$number '$label' removed"
}

# mbl_apply_clear_claim <repo> <number> — retire an ORPHANED `status: claimed`: remove the
# label AND clear the lease-less (orphan) assignee. Clearing the assignee is load-bearing,
# not cosmetic: frontier.sh excludes any issue with a non-empty assignees array and
# reclaim.sh returns early on a lease-less assignment ("no active lease record") without
# clearing it — so removing only the label would leave the issue permanently invisible to
# every worker. Re-verifies not-in-flight immediately before clearing (a claim that landed
# since planning wins — never disrupt it). The gated runbook (README.md "Post-merge runbook")
# runs this serialized and owner-approved, not concurrent with live claim sessions, so the
# fresh in-flight re-check covers the race the worker-protocol 60s re-read window guards.
mbl_apply_clear_claim() {
  local repo="$1" number="$2" assignees login
  if mbl_issue_in_flight "$repo" "$number"; then
    log "  #$number became in-flight since planning — keeping '$LABEL_CLAIMED', clear skipped"
    return 0
  fi
  mbl_apply_remove_label "$repo" "$number" "$LABEL_CLAIMED" \
    "Retiring \`$LABEL_CLAIMED\` — claim state is the assignee + lease trail now (EPIC #1491). No active claim on this issue." || return 1
  # Clear the orphan assignee(s) so the issue re-enters the frontier. Re-read live (never
  # act on the plan's recorded login — dynamic-lookup-over-recorded-state).
  assignees="$(gh issue view "$number" -R "$repo" --json assignees --jq '.assignees[].login' 2>/dev/null)" || {
    log "  #$number assignee re-read FAILED — label retired but assignee not cleared, review manually"
    return 1
  }
  [[ -z "$assignees" ]] && return 0
  while IFS= read -r login; do
    [[ -z "$login" ]] && continue
    if ! gh_write issue edit "$number" -R "$repo" --remove-assignee "$login" >/dev/null; then
      log "  #$number orphan assignee '$login' removal FAILED — review manually"
      return 1
    fi
  done <<<"$assignees"
  if ! gh_write issue comment "$number" -R "$repo" \
    --body "claim-state cleanup — cleared orphan assignee(s) with no live lease or open PR during the status-label migration (EPIC #1491; docs/conventions/worker-protocol.md \"Claim protocol\")." >/dev/null; then
    log "  #$number cleanup note failed to post — assignee(s) cleared, review manually"
    return 1
  fi
  log "  #$number orphan assignee(s) cleared"
}

# mbl_apply_delete_label <repo> <label> — delete the label definition, but ONLY when no
# issue still carries it. A still-referenced label (e.g. an in-flight claim) refuses
# deletion so in-flight work is never stranded.
mbl_apply_delete_label() {
  local repo="$1" label="$2" remaining rc
  remaining="$(gh issue list -R "$repo" --label "$label" --state all --limit "$LIMIT" --json number 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "  label '$label' deletion SKIPPED — could not verify it is unreferenced (exit $rc)"
    return 0
  fi
  if [[ "$(jq 'length' <<<"$remaining")" -ne 0 ]]; then
    log "  label '$label' still on $(jq 'length' <<<"$remaining") issue(s) — deletion refused (resolve in-flight items first)"
    return 0
  fi
  if ! gh_write label delete "$label" -R "$repo" --yes >/dev/null 2>&1; then
    # A non-zero delete is only benign if the label is genuinely gone; an auth /
    # provider error must not read as "already absent" (R14/R4). Re-verify.
    local names
    names="$(gh label list -R "$repo" --limit "$LIMIT" --json name --jq '.[].name' 2>/dev/null)"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log "  label '$label' delete FAILED and re-list could not verify (exit $rc) — provider error, review manually"
    elif grep -qxF "$label" <<<"$names"; then
      log "  label '$label' delete FAILED and it is still defined — provider error, review manually"
    else
      log "  label '$label' already absent — skip"
    fi
    return 0
  fi
  log "  label '$label' deleted"
}

# ===========================================================================
# Modes
# ===========================================================================

mbl_dry_run() {
  local repo="$1"
  log "== DRY RUN (read-only) — repo $repo, limit $LIMIT =="
  mbl_phase_entry_check "$repo"
  echo "# Proposed migration set for $repo (review before --apply)"
  echo "# status: blocked -> native blocked-by edges"
  mbl_plan_blocked "$repo"
  echo "# status: claimed -> assignee + lease (orphaned label + orphan assignee cleared)"
  mbl_plan_claimed "$repo"
  echo "# EXTERNAL lines are review-only (kept as-is) unless --apply --reify-external."
  echo "# SKIP-INFLIGHT / NO-BLOCKER issues keep their label; label deletion runs only"
  echo "# once a label is fully unreferenced."
}

mbl_apply() {
  local repo="$1" plan line kind number verb arg
  log "== APPLY (LIVE MUTATION) — repo $repo, limit $LIMIT =="
  mbl_phase_entry_check "$repo"
  plan="$(
    mbl_plan_blocked "$repo"
    mbl_plan_claimed "$repo"
  )" || {
    log "plan generation failed (provider error) — aborting before any mutation"
    exit "$EX_PROVIDER"
  }
  # Issues with an unresolved external blocker keep their label (never lose a
  # dependency to a silent removal); their numbers accumulate here.
  local -A hold_blocked=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r kind number verb arg <<<"$line"
    case "$kind:$verb" in
      BLOCKED:EDGE) mbl_apply_edge "$repo" "$number" "${arg#internal:}" || hold_blocked[$number]=1 ;;
      BLOCKED:EXTERNAL)
        local ext title reified_json reified
        ext="${arg#external:}"
        if [[ "$REIFY_EXTERNAL" != "true" ]]; then
          log "  #$number external dependency (review-only): '$ext' — keeping '$LABEL_BLOCKED'; pass --reify-external to convert vetted ones"
          hold_blocked[$number]=1
          continue
        fi
        # The seam has no --jq; capture the item JSON and extract .id here. Create the
        # reified blocker in the TARGET repo so the id we link back is a $repo number.
        title="external blocker: $ext"
        reified_json="$(bash "$SEAM" create-item --repo "$repo" --title "$title" --labels "$REIFY_LABEL" \
          --body "Reified from #$number during the status-label migration (EPIC #1491).")" || reified_json=""
        reified="$(jq -r '.id // empty' <<<"$reified_json" 2>/dev/null | sed -E 's/.*#([0-9]+)$/\1/')"
        if [[ ! "$reified" =~ ^[0-9]+$ ]]; then
          log "  #$number reify FAILED for '$ext' — keeping '$LABEL_BLOCKED', review manually"
          hold_blocked[$number]=1
          continue
        fi
        mbl_apply_edge "$repo" "$number" "$reified" || hold_blocked[$number]=1
        ;;
      BLOCKED:SKIP-INFLIGHT)
        # Held for the whole pass: no edge is created for in-flight issues, so the
        # removal pass must keep the label even if the PR closes / lease releases
        # mid-run — never strand the dependency with neither label nor edge.
        log "  #$number blocked+in-flight — never retro-block; keeping '$LABEL_BLOCKED'"
        hold_blocked[$number]=1
        ;;
      BLOCKED:NO-BLOCKER)
        log "  #$number has '$LABEL_BLOCKED' but no parseable blocker — keeping label, review manually"
        hold_blocked[$number]=1
        ;;
      CLAIMED:CLEAR) mbl_apply_clear_claim "$repo" "$number" ;;
      CLAIMED:SKIP-INFLIGHT) log "  #$number claimed+in-flight — left as-is (never disrupt in-flight work)" ;;
      *) log "  unrecognized plan line: $line" ;;
    esac
  done <<<"$plan"

  # Per-issue blocked-label removal (edges are the SSOT once created). Skip in-flight
  # items and any issue still holding an unresolved external/unparsed blocker.
  local issues n i num
  issues="$(mbl_fetch_issues "$repo" "$LABEL_BLOCKED")" || exit "$EX_PROVIDER"
  n="$(jq 'length' <<<"$issues")"
  for ((i = 0; i < n; i++)); do
    num="$(jq -r ".[$i].number" <<<"$issues")"
    if mbl_issue_in_flight "$repo" "$num"; then continue; fi
    if [[ -n "${hold_blocked[$num]:-}" ]]; then
      log "  #$num retains '$LABEL_BLOCKED' — unresolved blocker held for review"
      continue
    fi
    mbl_apply_remove_label "$repo" "$num" "$LABEL_BLOCKED" \
      "Retiring \`$LABEL_BLOCKED\` — dependencies are native blocked-by edges now (EPIC #1491)."
  done

  # Delete the retired label definitions last, and only when unreferenced.
  mbl_apply_delete_label "$repo" "$LABEL_BLOCKED"
  mbl_apply_delete_label "$repo" "$LABEL_CLAIMED"
}

mbl_verify() {
  local repo="$1" labels rc verdict issues fail=0
  log "== VERIFY (read-only) — repo $repo, limit $LIMIT =="
  labels="$(gh label list -R "$repo" --limit "$LIMIT" --json name 2>/dev/null)"
  rc=$?
  local lbl
  for lbl in "$LABEL_BLOCKED" "$LABEL_CLAIMED"; do
    verdict="$(mbl_absence_verdict "$rc" "$labels" "\"$lbl\"")" || true
    case "$verdict" in
      ABSENT) echo "OK   label '$lbl' fully retired" ;;
      PRESENT)
        echo "FAIL label '$lbl' still defined"
        fail=1
        ;;
      ERROR)
        echo "FAIL label fetch failed (exit $rc) — cannot certify retirement"
        fail=1
        ;;
      *)
        echo "FAIL unexpected verdict '$verdict'"
        fail=1
        ;;
    esac
    issues="$(gh issue list -R "$repo" --label "$lbl" --state all --limit "$LIMIT" --json number 2>/dev/null)"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "FAIL issue fetch for '$lbl' failed (exit $rc) — a failed fetch is never an empty set"
      fail=1
    elif [[ "$(jq 'length' <<<"$issues")" -ne 0 ]]; then
      echo "FAIL '$lbl' still on $(jq 'length' <<<"$issues") issue(s)"
      fail=1
    else
      echo "OK   no issue carries '$lbl'"
    fi
    labels="$(gh label list -R "$repo" --limit "$LIMIT" --json name 2>/dev/null)"
    rc=$?
  done
  [[ "$fail" -eq 0 ]] || return 1
}

usage() {
  cat >&2 <<EOF
Usage: migrate-blocked-labels.sh [--dry-run|--apply|--verify] [--repo <owner>/<repo>] [--limit <n>]

  --dry-run   (DEFAULT) read-only; emit the proposed migration set for review
  --apply     GATED live migration (edges, label removal, label deletion)
  --verify    read-only post-migration sanity checks

  --repo      target repo (default: current repo via gh)
  --limit     enumeration ceiling (default: $DEFAULT_LIMIT; beats gh's 30-row truncation)
  --reify-external  with --apply, convert vetted external blockers to wayfind: task
                    items (default: external blockers are review-only, label retained)

Runbook + prepared #1273 flip and doc edits: README.md in this directory.
EOF
}

migrate_main() {
  local mode="dry-run" repo="" limit=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) mode="dry-run" ;;
      --apply) mode="apply" ;;
      --verify) mode="verify" ;;
      --reify-external) REIFY_EXTERNAL="true" ;;
      --repo)
        [[ $# -ge 2 ]] || {
          usage
          exit "$EX_USAGE"
        }
        repo="$2"
        shift
        ;;
      --limit)
        [[ $# -ge 2 ]] || {
          usage
          exit "$EX_USAGE"
        }
        limit="$2"
        shift
        ;;
      -h | --help)
        usage
        exit "$EX_OK"
        ;;
      *)
        usage
        exit "$EX_USAGE"
        ;;
    esac
    shift
  done

  LIMIT="${limit:-$DEFAULT_LIMIT}"
  [[ "$LIMIT" =~ ^[0-9]+$ ]] || {
    log "--limit must be a positive integer"
    exit "$EX_USAGE"
  }

  mbl_require_prereqs
  if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)" || {
      log "could not resolve current repo — pass --repo <owner>/<repo>"
      exit "$EX_USAGE"
    }
  fi

  case "$mode" in
    dry-run) mbl_dry_run "$repo" ;;
    apply) mbl_apply "$repo" ;;
    verify) mbl_verify "$repo" ;;
    *)
      usage
      exit "$EX_USAGE"
      ;;
  esac
}

# Entrypoint guard: run only when executed, not when sourced by the test.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  migrate_main "$@"
fi
