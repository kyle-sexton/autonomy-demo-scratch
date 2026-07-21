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

# The C2 accumulation window opens at the first GENUINE scheduled fire; warm-up
# and manual rows completed before it never count toward the C2 predicate.
# predicate-c2.sh passes this into the DuckDB query (completed_at >= start).
# shellcheck disable=SC2034  # consumed by predicate-c2.sh via sed substitution
readonly DRAIN_WINDOW_START_UTC="2026-07-21T08:05:40Z"

# Run worktrees dispatch materializes for the inner session, kept OUTSIDE the
# repo tree (a sibling dir) so git never sees them as working-tree changes.
# Overridable for the Phase 2 Desktop scheduler surface.
DRAIN_WORKTREE_ROOT="${DRAIN_WORKTREE_ROOT:-${DRAIN_MAIN_ROOT%/*}/.autonomy-drain-worktrees}"

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
