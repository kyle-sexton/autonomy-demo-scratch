#!/usr/bin/env bash
# Shared constants and helpers for the autonomy-demo drain pipeline: the
# drain-next.sh entrypoint, the dispatch-item.sh wrapper, verify-join.sh, and
# backup-evidence.sh. Sourced, never executed.
#
# This file is the single home for the cross-script name couplings that fail
# SILENTLY on drift:
#   - DRAIN_GATE_CHECK_NAME: the deterministic-gate check-run name verify-join
#     reads from the check-run API; the gate workflow job MUST carry it too.
#   - DRAIN_BRANCH_PREFIX: dispatch creates the per-run work branch under it;
#     drain reconcile scans the same prefix for branches without PRs.
#   - the evidence/run-state paths every script reads and appends.

[[ -n "${_DRAIN_COMMON_LOADED:-}" ]] && return 0
readonly _DRAIN_COMMON_LOADED=1

DRAIN_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DRAIN_REPO_ROOT

# Directory holding this lib and its sidecar assets (candidate-filter.jq). The
# candidate-eligibility jq program lives in a file both drain-next.sh (via
# drain_select_candidates) and the gate test runner read, so the test cannot
# drift from production.
DRAIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DRAIN_LIB_DIR

# Durable surfaces anchor to the MAIN checkout, not the current working tree:
# scheduler surfaces run these scripts from ephemeral worktrees, and evidence
# appended to a worktree-relative path is lost when the worktree is pruned.
# --git-common-dir resolves to the main checkout's .git from any worktree.
DRAIN_MAIN_ROOT="$(cd "$(git -C "$DRAIN_REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
readonly DRAIN_MAIN_ROOT

DRAIN_ARTIFACT_DIR="${DRAIN_ARTIFACT_DIR:-${DRAIN_MAIN_ROOT}/.artifacts}"
# shellcheck disable=SC2034  # consumed by verify-join.sh / backup-evidence.sh, which source this lib
DRAIN_PIPELINE="${DRAIN_ARTIFACT_DIR}/pipeline.jsonl"
DRAIN_RUN_STATE="${DRAIN_ARTIFACT_DIR}/drain-runs.jsonl"

# The gate's check-run name (== the gate workflow job name). verify-join.sh reads
# the gate outcome from the check-run API by this exact string.
# shellcheck disable=SC2034  # consumed by verify-join.sh, which sources this lib
readonly DRAIN_GATE_CHECK_NAME="deterministic-gate"

# Per-run work branch: dispatch creates `<prefix>/<issue>/<run_id>`.
# shellcheck disable=SC2034  # consumed by dispatch-item.sh / drain-next.sh, which source this lib
readonly DRAIN_BRANCH_PREFIX="autonomy/drain"

# Work-item lease TTL (whole hours) drain-next.sh passes to the tracker's claim.sh.
# STOPGAP at 1h: the intended value is 30min (runs finish in ~3.5min; at the 15-min
# cadence a stuck lease should not block more than ~2 cycles), but the work-item-tracker
# lease protocol is integer-hours only (claim.sh / lib/lease.sh / CONTRACT.md) and that
# tracker is an upstream-synced vendored seam — sub-hour granularity is an upstream
# protocol change, not a local edit. 1h = 4 cycles, tolerable because the PRIMARY
# stuck-claim recovery is drain-next.sh's reconcile preamble (it releases a dead run's
# lease); this TTL is only the backstop for a claim the reconcile never sees.
# TODO(melodic-software/claude-code-plugins#1034): restore to 30min once sub-hour lease TTL lands upstream.
# shellcheck disable=SC2034  # consumed by drain-next.sh, which sources this lib
readonly DRAIN_LEASE_TTL_HOURS=1

# The C2 accumulation window opens at the first GENUINE scheduled fire; warm-up
# and manual rows completed before it never count toward the C2 predicate.
# predicate-c2.sh passes this into the DuckDB query (completed_at >= start).
# shellcheck disable=SC2034  # consumed by predicate-c2.sh via sed substitution
readonly DRAIN_WINDOW_START_UTC="2026-07-21T08:05:40Z"

# Run worktrees dispatch materializes for the inner session, kept OUTSIDE the
# repo tree (a sibling dir) so git never sees them as working-tree changes.
# Overridable for the Phase 2 Desktop scheduler surface.
DRAIN_WORKTREE_ROOT="${DRAIN_WORKTREE_ROOT:-${DRAIN_MAIN_ROOT%/*}/.autonomy-drain-worktrees}"

# --- fire-origin attestation (attest-fire-origin.sh) ------------------------
# The Desktop task stamps fire_kind from a hardcoded --fire-kind flag, so a manual
# "Run now" self-stamps as `scheduled`. attest-fire-origin.sh does NOT trust that
# stamp; it reconstructs fire origin from outer-session transcript evidence. The
# constants below are the couplings that reconstruction depends on.

# Must equal the Desktop task id AND the `name` attribute in the outer transcript's
# <scheduled-task name="..."> tag: attest matches enqueue records on this string.
# shellcheck disable=SC2034  # consumed by attest-fire-origin.sh, which sources this lib
readonly DRAIN_SCHEDULED_TASK_NAME="autonomy-demo-hourly-drain"

# Cron-slot grid the scheduler fires on, as a repeating period anchored at a
# minute-of-hour. Coupled to the Desktop task's cronExpression: the every-15-min
# grid `*/15 * * * *` is period 15, anchor 0 (slots at :00/:15/:30/:45). Like
# DRAIN_GATE_CHECK_NAME, this coupling fails SILENTLY on drift: if the scheduler's
# grid changes and these constants do not, genuine fires read as off-schedule.
# slot_offset = ((enqueue_epoch - anchor*60) mod period*60), i.e. seconds since the
# most recent slot; correct for any period that divides 3600 evenly (15 does), which
# keeps the UTC-aligned slots fact-2 confirms. The prior hourly grid was period 60,
# anchor 0; an old-cadence hourly enqueue (+~330s past the hour) still lands within
# tolerance of a period-15/anchor-0 slot, so the transition needs no special-casing.
# shellcheck disable=SC2034  # consumed by attest-fire-origin.sh, which sources this lib
readonly DRAIN_SLOT_PERIOD_MINUTES=15
# shellcheck disable=SC2034  # consumed by attest-fire-origin.sh, which sources this lib
readonly DRAIN_SLOT_ANCHOR_MINUTE=0

# Max seconds after a slot an enqueue may land and still attest as scheduled.
# Observed genuine app dispatch delay is +320–335s past the slot; 480s leaves ~145s of
# headroom above that while staying well under the 900s slot period. Do NOT tighten
# below 480s: the headroom absorbs scheduler-load drift on the +320–335s spread.
# RESIDUAL (accepted): at the 15-min cadence a manual "Run now" attests-as-scheduled
# whenever it lands within DRAIN_FIRE_TOLERANCE_S of ANY of the four hourly slots —
# ~4*480/3600 ≈ 53% of the hour, versus ~600/3600 ≈ 17% under the old hourly/600s grid.
# The growth is inherent to the higher cadence (four slots, not one), not the 600->480
# tightening. Accepted because: (a) the threat model is an ACCIDENTAL operator kick,
# and manual Run-now is procedurally forbidden during the C2 accumulation window;
# (b) the originating-transcript join, not this slot check, is the primary classifier
# (the slot check only screens a run that ALREADY joined a task-tagged enqueue); and
# (c) a mechanical post-merge watcher (repo issue #41) is a required precondition before
# any autonomy promotion, catching a false-scheduled completion downstream regardless.
# shellcheck disable=SC2034  # consumed by attest-fire-origin.sh, which sources this lib
readonly DRAIN_FIRE_TOLERANCE_S=480

# Max seconds between an outer-session enqueue and the run_id's embedded start for
# that transcript to count as the ORIGINATING session (drain start is 30s–7min after
# enqueue). Disambiguates the originating fire from later reconcile fires that merely
# mention an old run_id in their own transcripts.
# THIN MARGIN at the 15-min cadence: this window (900s) now EQUALS the slot period
# (DRAIN_SLOT_PERIOD_MINUTES*60 = 900s), so adjacent fires lack the hourly grid's
# comfortable spacing. Single-candidate still holds only because a run starts >=~30s
# after its OWN enqueue, pushing the PREVIOUS slot's enqueue >900s before the run start
# (out of window) — worst case ~915s given the observed +320–335s dispatch spread. If
# that margin were ever violated, the run matches two in-window enqueues and reads
# ambiguous-origin => EXCLUDED (fail-closed): a dropped genuine completion, never a
# false attestation. Documented here (not silently relied on) per this repo's
# silent-drift-at-constant-sites convention; revisit if the cadence tightens further.
# shellcheck disable=SC2034  # consumed by attest-fire-origin.sh, which sources this lib
readonly DRAIN_ATTEST_JOIN_WINDOW_S=900

# Outer-session transcript root: $HOME/.claude/projects/<slug>/<uuid>.jsonl.
# Overridable so the gate test can point it at synthetic fixtures.
DRAIN_TRANSCRIPT_ROOT="${DRAIN_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"

# Durable materialized positive attestations. Transcripts get garbage-collected, so
# a once-attested run must survive that: attest-fire-origin.sh --record appends here
# and re-emits from here when the originating transcript is gone.
DRAIN_ATTESTATIONS="${DRAIN_ATTESTATIONS:-${DRAIN_ARTIFACT_DIR}/fire-attestations.jsonl}"

# Append-only demotion-event log the post-merge watcher (watch-demotion.sh) writes when
# a drained merge stops standing (gate regressed / human revert). Overridable for tests.
# shellcheck disable=SC2034  # consumed by watch-demotion.sh, which sources this lib
DRAIN_DEMOTION_EVENTS="${DRAIN_DEMOTION_EVENTS:-${DRAIN_ARTIFACT_DIR}/demotion-events.jsonl}"

drain_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# drain_binding_store_path — the OTel session store filesystem path derived from
# the binding's routines.enabled.*.run_link_prefix (the one place the machine
# store location is declared). Empty when no binding / no prefix is present.
# Converts the file:// URL form to a filesystem path, stripping the leading slash
# only ahead of a Windows drive (file:///C:/x -> C:/x; file:///var/x -> /var/x).
drain_binding_store_path() {
  local binding="${DRAIN_REPO_ROOT}/.claude/autonomy/binding.json" prefix=""
  [[ -f "$binding" ]] || { printf ''; return 0; }
  prefix="$(jq -r 'first(.routines.enabled[]?.run_link_prefix // empty) // empty' \
    "$binding" 2>/dev/null || true)"
  [[ -n "$prefix" ]] || { printf ''; return 0; }
  prefix="${prefix#file://}"
  [[ "$prefix" =~ ^/[A-Za-z]:/ ]] && prefix="${prefix#/}"
  printf '%s\n' "${prefix%/}"
}

# drain_otel_store — resolved OTel session store path. Resolution order:
# DRAIN_OTEL_STORE env -> CC_OTEL_STORE env -> binding run_link_prefix. FAILS
# CLOSED (return 1, no machine-literal fallback) when none resolves; a direct
# `store="$(drain_otel_store)"` assignment then aborts the caller under set -e.
drain_otel_store() {
  if [[ -n "${_DRAIN_OTEL_STORE_CACHE:-}" ]]; then
    printf '%s\n' "$_DRAIN_OTEL_STORE_CACHE"
    return 0
  fi
  local v="${DRAIN_OTEL_STORE:-${CC_OTEL_STORE:-}}"
  [[ -n "$v" ]] || v="$(drain_binding_store_path)"
  [[ -n "$v" ]] || {
    echo "drain: OTel session store unresolved; set DRAIN_OTEL_STORE (or CC_OTEL_STORE), or populate routines.enabled.*.run_link_prefix in .claude/autonomy/binding.json" >&2
    return 1
  }
  _DRAIN_OTEL_STORE_CACHE="$v"
  printf '%s\n' "$v"
}

# drain_operator_login — the account identity the return-accounting record
# attributes to and @-mentions. Resolution order: binding
# routines.enabled.*.producer_identity (when non-null) -> `gh api user`. No
# literal fallback: an unresolvable identity fails closed under set -e rather
# than writing a wrong/empty owner into the attestation record.
drain_operator_login() {
  if [[ -n "${_DRAIN_OPERATOR_LOGIN_CACHE:-}" ]]; then
    printf '%s\n' "$_DRAIN_OPERATOR_LOGIN_CACHE"
    return 0
  fi
  local id="" binding="${DRAIN_REPO_ROOT}/.claude/autonomy/binding.json"
  if [[ -f "$binding" ]]; then
    id="$(jq -r 'first(.routines.enabled[]?.producer_identity // empty) // empty' \
      "$binding" 2>/dev/null || true)"
  fi
  [[ -n "$id" ]] || id="$(gh api user --jq .login)"
  _DRAIN_OPERATOR_LOGIN_CACHE="$id"
  printf '%s\n' "$id"
}

# drain_c2_label — the label the drain claims on. Resolution order: env override,
# then the binding's optional triggers.drain.work_class_label, then the
# contract-suggested default. The label->class RULES stay governance-owned in the
# plugins repo; this is only the local label NAME the drain filters candidates by.
drain_c2_label() {
  if [[ -n "${DRAIN_C2_LABEL:-}" ]]; then
    printf '%s\n' "$DRAIN_C2_LABEL"
    return 0
  fi
  local binding="${DRAIN_REPO_ROOT}/.claude/autonomy/binding.json" lbl=""
  if [[ -f "$binding" ]]; then
    lbl="$(jq -r '.triggers.drain.work_class_label // empty' "$binding" 2>/dev/null || true)"
  fi
  printf '%s\n' "${lbl:-work-class: c2}"
}

# drain_class_from_label <label> — extract the C-class token (C1..C5) the label
# encodes, uppercased. Trivial local extraction only; the authoritative
# label->class rules live on the security governance surface (plugins repo).
drain_class_from_label() {
  local tok
  tok="$(printf '%s' "$1" | grep -oiE 'c[1-5]' | head -1 | tr '[:lower:]' '[:upper:]')"
  printf '%s\n' "${tok:-C2}"
}

# drain_owner_repo — owner/name of the repo the CWD checkout points at.
drain_owner_repo() { gh repo view --json nameWithOwner --jq .nameWithOwner; }

# drain_item_url <owner/repo> <issue>
drain_item_url() { printf 'https://github.com/%s/issues/%s\n' "$1" "$2"; }

# drain_timeout_bin — path to GNU coreutils `timeout`, or empty when only a
# non-coreutils `timeout` (e.g. Windows timeout.exe, which PAUSES rather than
# killing) is resolvable. Callers guard on empty and fail closed.
drain_timeout_bin() {
  local bin
  bin="$(command -v timeout 2>/dev/null || true)"
  [[ -n "$bin" ]] || {
    printf ''
    return 0
  }
  if "$bin" --version 2>/dev/null | grep -qi coreutils; then
    printf '%s\n' "$bin"
  else
    printf ''
  fi
}

# drain_new_run_id <fire_kind> — per-run identity stamped into the lease
# session_id, the wrapper span, the OTel resource attrs, and the return record.
# Phase 1: fire_kind is a best-effort LOCAL stand-in. Platform-attested
# scheduled-fire identity (trigger-dispatch.md "Authenticated run context") does
# not exist until the Phase 2 Desktop scheduler surface runs the drain.
drain_new_run_id() {
  local kind="${1:-manual}" rand
  rand="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s-%s-%s\n' "$kind" "$(date -u +%Y%m%dT%H%M%SZ)" "$rand"
}

# drain_record_run <json-object> — append one run-state record (append-only;
# reconcile flattens last-status-per-run_id, the same pattern verify-join uses).
drain_record_run() {
  mkdir -p "$DRAIN_ARTIFACT_DIR"
  printf '%s\n' "$1" >>"$DRAIN_RUN_STATE"
}

# drain_select_candidates <label> — read raw tracker list-items JSON on stdin and
# emit eligible candidates as `<id>\t<url>` TSV, one per line, sorted by issue
# number: items carrying <label> AND unblocked AND unassigned. The eligibility
# jq program is candidate-filter.jq (shared with the gate test runner, so the test
# cannot drift from production).
#
# The trailing `tr -d '\r'` strips the carriage return jq.exe appends to each
# output line under Windows text-mode stdout: without it the CR rides into the
# last @tsv field and contaminates every downstream item_url (seen historically as
# "...issues/10\r" in drain-runs.jsonl). Stripping here — at the one boundary the
# value crosses into this pipeline — fixes it once for every consumer, rather than
# per downstream use. jq.exe is the actual injection point (the tracker adapter's
# output is CR-free); this strip also hardens the seam against any future adapter
# that emits CR.
drain_select_candidates() {
  local lbl="$1"
  jq -r --arg lbl "$lbl" -f "${DRAIN_LIB_DIR}/candidate-filter.jq" | tr -d '\r'
}

# drain_revert_sha <repo_dir> <merge_sha> <ref> — SHA of a commit reachable from
# <ref> but not from <merge_sha> whose message reverts the merge ("This reverts
# commit <full merge_sha>", the line both `git revert` and GitHub's Revert-PR
# button write). In the normal case (<merge_sha> on <ref>'s history) that set is
# the commits AFTER the merge. Reads committed history only; the caller refreshes
# <ref> first so the read observes the merged-then-reverted state.
#
# Return contract — the caller MUST distinguish these, because "unknown" feeds the
# eligibility gate and must fail CLOSED:
#   rc 0, empty  -> determinable AND unreverted (the legitimate clean case)
#   rc 0, sha    -> reverted (prints the reverting commit's sha)
#   rc != 0      -> UNDETERMINABLE: git could not read the range (<ref> or
#                   <merge_sha> unfetched/invalid). NEVER treat as clean.
drain_revert_sha() {
  local repo_dir="$1" merge_sha="$2" ref="${3:-origin/main}" out rc
  [[ -n "$merge_sha" ]] || {
    printf ''
    return 0
  }
  # Capture git's own exit separately from the pipeline so a read failure is not
  # masked into an empty "no match" (which would fail open).
  out="$(git -C "$repo_dir" log --format=%H --fixed-strings \
    --grep="This reverts commit ${merge_sha}" "${merge_sha}..${ref}" 2>/dev/null)"
  rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  printf '%s\n' "${out%%$'\n'*}"
}

# A completion counts toward the C2 >=20-completions threshold only when its PR
# merged at least this long before evaluation time. A freshly merged PR can still be
# human-reverted inside the accumulation window; this delay keeps green-but-young
# completions from inflating the count before that revert signal can land. Young or
# unmerged completions are simply not YET mature — not an error. (Read by
# drain_merge_is_mature below, which predicate-c2.sh calls per join row.)
readonly DRAIN_MERGE_MATURITY_S=$((48 * 3600))

# drain_merge_is_mature <merged_at_iso|""|null> <now_epoch> — prints "true" when the
# merge timestamp is present AND at least DRAIN_MERGE_MATURITY_S seconds before
# <now_epoch>; "false" otherwise (unmerged, unparseable, timezone-naive, or too young).
# Pure; no network. `date -u -d` is GNU-only, matching the drain's other GNU date usage
# (attest-fire-origin.sh, dispatch-item.sh); available in Git Bash and ubuntu CI.
#
# FAIL CLOSED on a timezone-naive timestamp: GNU `date -d` parses an offset-less string
# in the machine's LOCAL zone (the -u flag only sets OUTPUT zone), which would shift the
# merge epoch by the local UTC offset and mis-judge maturity near the 48h boundary. So
# require an explicit UTC/offset marker (Z or ±hh:mm / ±hhmm). The gh source is always
# Z-suffixed, so this rejects only malformed input — no production behavior change.
drain_merge_is_mature() {
  local merged_at="$1" now_epoch="$2" mepoch
  [[ -n "$merged_at" && "$merged_at" != "null" ]] || { printf 'false\n'; return 0; }
  [[ "$merged_at" =~ (Z|[+-][0-9]{2}:?[0-9]{2})$ ]] || { printf 'false\n'; return 0; }
  mepoch="$(date -u -d "$merged_at" +%s 2>/dev/null || true)"
  [[ -n "$mepoch" ]] || { printf 'false\n'; return 0; }
  if (( now_epoch - mepoch >= DRAIN_MERGE_MATURITY_S )); then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# drain_reconcile_title <kind> <run_id> <issue> — the identity-carrying title a
# reconcile tracker item is keyed on. Dedup logic (drain_file_reconcile_item and
# the merged-but-open decision) compares against it, so the format lives here once.
drain_reconcile_title() {
  printf '[drain-reconcile] %s: run %s item #%s\n' "$1" "$2" "$3"
}

# drain_merged_but_open_flags <open_c2> <existing_titles> — PURE decision for the
# double-drain guard (no gh/network; all inputs supplied). Reads the merged-drain-PR
# map on stdin as "<issue>\t<pr>\t<run_id>" lines; <open_c2> is a newline-separated
# list of open C2-labelled issue numbers; <existing_titles> is the newline-separated
# already-open reconcile titles. Emits "<issue>\t<pr>\t<run_id>" for each merged PR
# whose issue is still OPEN+C2 AND has no reconcile item already filed (idempotent
# dedup by drain_reconcile_title). Extracted so it is unit-testable off fixtures.
drain_merged_but_open_flags() {
  local open_c2="$1" existing_titles="$2" issue pr run title
  while IFS=$'\t' read -r issue pr run; do
    [[ -n "$issue" ]] || continue
    printf '%s\n' "$open_c2" | grep -qxF "$issue" || continue
    title="$(drain_reconcile_title "merged-but-open" "${run:-unknown}" "$issue")"
    printf '%s\n' "$existing_titles" | grep -qxF "$title" && continue
    printf '%s\t%s\t%s\n' "$issue" "$pr" "$run"
  done
}

# --- shared merge-state resolution (verify-join.sh + watch-demotion.sh) ------
# The `gh pr view` / check-run-API projections both scripts need, hosted once so the
# resolution cannot drift between the acceptance-proof join and the post-merge net.

# drain_complete_runs <run_state_file> — emit the DISTINCT complete drain runs as a
# compact JSON array: last-status-per-run_id flattened (successive rows for a run_id are
# object-merged, so the terminal row's pr_url/status win), then filtered to
# status=="complete". This is the run-enumeration predicate-c2.sh and watch-demotion.sh
# share. A MISSING file yields `[]` (rc 0: no runs yet is a legitimate empty). A PRESENT
# but malformed file makes jq FAIL (non-zero propagates) — the helper never masks a parse
# error into an empty result; the caller decides fail-soft (predicate: not-eligible) vs
# fail-closed (watch-demotion: abort).
drain_complete_runs() {
  local f="$1"
  [[ -f "$f" ]] || { printf '[]\n'; return 0; }
  jq -sc '
    reduce .[] as $r ({}; .[$r.run_id] = ((.[$r.run_id] // {}) + $r))
    | [.[] | select((.status // "") == "complete")]' "$f"
}

# drain_pr_merge_state <pr_url> — resolve a PR's merge state from GitHub as TSV
# "<head_sha>\t<merge_sha>\t<merged_at>", any field empty when absent (an UNMERGED PR has
# empty merge_sha/merged_at). rc != 0 (gh transport/HTTP failure) means UNDETERMINABLE —
# the caller must NOT read a failed lookup as "unmerged". `tr -d '\r'` strips the gh.exe /
# jq.exe CRLF the Windows text-mode stdout appends (same boundary drain_select_candidates
# guards), so a stray CR never rides into a downstream sha / git range.
drain_pr_merge_state() {
  local pr_url="$1" j
  j="$(gh pr view "$pr_url" --json headRefOid,mergedAt,mergeCommit 2>/dev/null)" || return 3
  jq -r '[(.headRefOid // ""), (.mergeCommit.oid // ""), (.mergedAt // "")] | @tsv' <<<"$j" \
    | tr -d '\r'
}

# drain_gate_conclusion <owner_repo> <sha> — the deterministic-gate check-run conclusion
# on <sha> from GitHub's check-run API (the independent gate surface the agent never
# writes; keyed on DRAIN_GATE_CHECK_NAME == the gate workflow job name). Prints the
# conclusion string, or EMPTY when no deterministic-gate check-run exists on <sha> — a
# DETERMINED fact (e.g. the squash-merge commit carries none because the gate is
# pull_request-triggered), NOT an error. rc != 0 (gh transport/HTTP failure) means
# UNDETERMINABLE; the caller fails closed. `tr -d '\r'` guards the Windows CRLF boundary.
#
# `?per_page=100` (max page size) keeps the gate from falling off page 1: the check-run
# list defaults to 30 per page, so once a commit carries >30 distinct check names the gate
# could sit on an unfetched page and read as "" — which the verdict treats as contrary, a
# FALSE gate-regression. The param rides in the URL query string, NOT via `-f/-F`: a raw
# field would flip `gh api` from GET to POST (405/404). The API's default filter=latest
# already collapses re-run attempts of a name to its most recent, so the `[0]` stays correct.
drain_gate_conclusion() {
  local owner_repo="$1" sha="$2" out
  out="$(gh api "repos/${owner_repo}/commits/${sha}/check-runs?per_page=100" \
    --jq "[.check_runs[] | select(.name == \"${DRAIN_GATE_CHECK_NAME}\")][0].conclusion // \"\"" \
    2>/dev/null)" || return 3
  printf '%s\n' "$out" | tr -d '\r'
}

# drain_gate_verdict <conclusion> — classify a deterministic-gate conclusion for the
# post-merge net. Pure; no network. The GitHub check-run conclusion enum is fixed
# (success|failure|neutral|cancelled|timed_out|action_required|stale|skipped|
# startup_failure), plus EMPTY (no gate check-run found):
#   success                              -> clean         (the merge carries a passing gate)
#   "" or any non-success enum value     -> contrary      (merged without a passing gate:
#                                           a bypass or a post-merge regression -> event)
#   any unrecognized token               -> indeterminate (fail closed; caller aborts,
#                                           never reads an unclassifiable value as clean)
# EMPTY is `contrary` NOT `indeterminate` ON PURPOSE: watch-demotion only ever passes the
# FINAL authoritative conclusion here (it resolves the merge commit first, falling back to
# the PR head ONLY when the merge commit has no gate check-run), so an empty at this point
# is a merged PR head with no passing gate — a determined contrary fact, not a gap.
drain_gate_verdict() {
  case "$1" in
    success) printf 'clean\n' ;;
    '' | failure | neutral | cancelled | timed_out | action_required | stale | skipped | startup_failure)
      printf 'contrary\n' ;;
    *) printf 'indeterminate\n' ;;
  esac
}

# drain_demotion_already_recorded <kind> <merge_sha> <events_file> — the idempotency
# probe. The append key is (kind, merge_sha): re-running the watcher must not duplicate a
# row for an already-recorded event. Pure (jq over a local file); unit-tested off fixtures.
# Return contract — the caller MUST distinguish these, because a mis-read defeats dedup:
#   rc 0 -> already recorded (an event with this kind+merge_sha exists)
#   rc 1 -> NOT recorded (no such event, or a missing file — nothing appended yet)
#   rc 3 -> UNDETERMINABLE: the events file is present but jq could not parse it (rc >= 2:
#           corrupt/truncated write). FAIL CLOSED — the caller aborts rather than treating
#           it as "not recorded" and appending, which would permanently defeat the dedup
#           guarantee (every re-run would re-append) after a single truncated write. This
#           mirrors drain_complete_runs's malformed-evidence contract.
drain_demotion_already_recorded() {
  local kind="$1" merge_sha="$2" f="$3" rc
  [[ -f "$f" ]] || return 1
  jq -e -n --arg k "$kind" --arg m "$merge_sha" --slurpfile rows "$f" \
    'any($rows[]; .kind == $k and .merge_sha == $m)' >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;; # jq -e: 0 = truthy (found), 1 = false/null (not found)
    *) return 3 ;;         # jq parse/compile/IO error (rc >= 2) -> fail closed
  esac
}
