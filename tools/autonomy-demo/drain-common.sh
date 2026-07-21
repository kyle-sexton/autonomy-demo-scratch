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

DRAIN_ARTIFACT_DIR="${DRAIN_ARTIFACT_DIR:-${DRAIN_REPO_ROOT}/.artifacts}"
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

# Run worktrees dispatch materializes for the inner session, kept OUTSIDE the
# repo tree (a sibling dir) so git never sees them as working-tree changes.
# Overridable for the Phase 2 Desktop scheduler surface.
DRAIN_WORKTREE_ROOT="${DRAIN_WORKTREE_ROOT:-${DRAIN_REPO_ROOT%/*}/.autonomy-drain-worktrees}"

# Default OTel session store (matches verify-join and backup-evidence defaults).
DRAIN_OTEL_STORE="${DRAIN_OTEL_STORE:-${CC_OTEL_STORE:-C:/ProgramData/local-otel/cc-store}}"

drain_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

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
