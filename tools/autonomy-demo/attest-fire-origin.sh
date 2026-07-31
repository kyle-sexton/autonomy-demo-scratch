#!/usr/bin/env bash
# Deterministic fire-origin attestation for drain runs. The Desktop task stamps
# fire_kind from a hardcoded --fire-kind flag baked into its SKILL.md, so a manual
# "Run now" from the app self-stamps as `scheduled`. The C2 promotion predicate must
# NOT trust that stamp; this verifier reconstructs fire origin from outer-session
# transcript evidence instead, and FAILS CLOSED at every step (any missing/ambiguous
# evidence => fire_attested=false with a specific reason).
#
# Two attestation paths, branched on the run_id's kind prefix (scratch#42):
#   scheduled-*  — originating-transcript join + cron-slot alignment (below).
#   labeled-*    — event-driven fire: the run's recorded kick_ref (the label-kick relay
#                  workflow run id, see .github/workflows/label-kick.yml) is verified
#                  against GitHub's own record of that run — workflow path, event kind,
#                  run-name-encoded label, a bounded kick->run-start window, and the
#                  claim's EXCLUSIVITY: one kick attests one run, so a kick_ref two runs
#                  recorded (a retried dispatch delivery) attests neither
#                  (drain_labeled_kick_attest, drain-common.sh). This path reads the
#                  run-state file for the kick_ref and its rival claimants and, unless
#                  DRAIN_RELAY_RUNS_FILE
#                  points at a local record set (tests), the GitHub API for the run
#                  record — a gh transport failure emits relay-unreadable (excluded,
#                  never persisted, recomputable — same posture as a GC'd transcript).
#   anything else (manual-*, malformed) — not-scheduled-kind, i.e. not an attestable
#                  fire kind.
#
# Threat model: the target is an ACCIDENTAL operator manual kick that self-stamps as
# scheduled, NOT an adversarial operator. An operator owns the machine and could
# forge transcripts; defending against that is out of scope. Residual (accepted and
# documented): a manual Run-now that happens to enqueue within DRAIN_FIRE_TOLERANCE_S
# of ANY grid slot attests falsely as scheduled. At the 15-min cadence that residual
# is ~4x the hourly grid's (four slots per hour, not one) — inherent to the higher
# cadence; DRAIN_FIRE_TOLERANCE_S is sized for headroom over genuine dispatch delay,
# not to shrink this residual.
#
# Read-only except with --record, which materializes each NEWLY-computed POSITIVE
# attestation to DRAIN_ATTESTATIONS (durability across transcript garbage-collection).
# Negatives are never persisted: a transcript may reappear or tolerance may be
# corrected, so negatives must stay recomputable.
#
# Usage: attest-fire-origin.sh [--record] <run_id> [<run_id>...]
# Emits one compact JSON line per run_id to stdout:
#   {"run_id":..,"fire_attested":bool,"reason":..,"enqueue_ts":..|null,
#    "transcript":..|null,"slot_offset_s":..|null}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

record=0
if [[ "${1:-}" == "--record" ]]; then
  record=1
  shift
fi
[[ "$#" -gt 0 ]] || { echo "usage: attest-fire-origin.sh [--record] <run_id> [<run_id>...]" >&2; exit 2; }

# emit <run_id> <attested:0|1> <reason> <enqueue_ts|""> <transcript|""> <slot_offset|"">
emit() {
  jq -cn --arg rid "$1" --argjson att "$2" --arg reason "$3" \
    --arg ets "$4" --arg tr "$5" --arg off "$6" \
    '{run_id: $rid, fire_attested: ($att == 1), reason: $reason,
      enqueue_ts: (if $ets == "" then null else $ets end),
      transcript: (if $tr == "" then null else $tr end),
      slot_offset_s: (if $off == "" then null else ($off | tonumber) end)}'
}

# ts_to_epoch / enqueue_ts_of moved to drain-common.sh as drain_ts_to_epoch /
# drain_enqueue_ts_of (detect-missed-fire.sh needs the same primitives to mine every
# task-tagged enqueue across all transcripts, not just those matching one run_id).

# kick_ref_of <run_id> — the kick_ref recorded on the run's run-state rows (drain-next.sh
# records it on the claimed row of a labeled fire), via the same last-status-per-run_id
# flatten every other run-state reader uses. Empty when the file or the field is absent
# (the caller fails closed).
kick_ref_of() {
  [[ -f "$DRAIN_RUN_STATE" ]] || return 0
  jq -sr --arg rid "$1" '
    reduce .[] as $r ({}; .[$r.run_id] = ((.[$r.run_id] // {}) + $r))
    | .[$rid].kick_ref // empty' "$DRAIN_RUN_STATE" 2>/dev/null | tr -d '\r' || true
}

# kick_rivals_of <run_id> <kick_ref> — the OTHER runs whose run-state rows record the same
# kick_ref, one per line (empty when the claim is exclusive). One kick attests one run, and
# a retried dispatch delivery can start two labeled runs against a single relay record, so
# the exclusivity of the claim is evidence the attestation depends on. Same
# last-status-per-run_id flatten kick_ref_of uses; kick_ref is compared as a string because
# the run-state value is a workflow-run id that may have been recorded either way.
kick_rivals_of() {
  [[ -f "$DRAIN_RUN_STATE" ]] || return 0
  jq -sr --arg rid "$1" --arg ref "$2" '
    reduce .[] as $r ({}; .[$r.run_id] = ((.[$r.run_id] // {}) + $r))
    | to_entries[]
    | select(.key != $rid and ((.value.kick_ref // "") | tostring) == $ref)
    | .key' "$DRAIN_RUN_STATE" 2>/dev/null | tr -d '\r' || true
}

# kick_record_of <kick_ref> — the {path, event, display_title, created_at} projection of
# the relay workflow run the kick_ref names. Source is the GitHub API (the platform's
# authenticated record — never agent-writable state); DRAIN_RELAY_RUNS_FILE overrides it
# with a local JSONL record set ({id, path, event, display_title, created_at} per line)
# so the gate tier can exercise the branch without network. Prints nothing when the run
# is unknown; rc 3 when the source itself is unreadable (gh transport failure /
# unparseable override file) — the caller must distinguish unknown from unreadable.
kick_record_of() {
  local ref="$1" out
  if [[ -n "${DRAIN_RELAY_RUNS_FILE:-}" ]]; then
    out="$(jq -c --arg id "$ref" 'select((.id | tostring) == $id)
      | {path, event, display_title, created_at}' "$DRAIN_RELAY_RUNS_FILE" 2>/dev/null)" \
      || return 3
    printf '%s\n' "$out" | head -1
    return 0
  fi
  out="$(gh api "repos/$(drain_owner_repo)/actions/runs/${ref}" \
    --jq '{path, event, display_title, created_at}' 2>/dev/null)" || return 3
  printf '%s\n' "$out" | tr -d '\r'
}

for run_id in "$@"; do
  # Defensive CR strip: a caller extracting run_ids via jq.exe under Windows text-mode
  # stdout hands us a trailing CR (the repo's known jq.exe CRLF boundary); left in, it
  # fails the scheduled-kind regex and every real run reads not-scheduled-kind.
  run_id="${run_id%$'\r'}"
  # 1. Durability shortcut: a prior POSITIVE record short-circuits the rest, so a
  #    run whose originating transcript was GC'd still attests. Only positives are
  #    ever persisted, so any stored record for this run_id is a positive.
  if [[ -f "$DRAIN_ATTESTATIONS" ]]; then
    prior="$(jq -c --arg rid "$run_id" \
      'select(.run_id == $rid and .fire_attested == true)' \
      "$DRAIN_ATTESTATIONS" 2>/dev/null | head -1 || true)"
    if [[ -n "$prior" ]]; then
      jq -c '.reason = "recorded"' <<<"$prior"
      continue
    fi
  fi

  # 2a. labeled-kind (scratch#42): verify the run's RECORDED kick claim against the
  # platform's record of the relay workflow run it names. Every step fails closed:
  # no run-state kick_ref => no-kick-ref; source unreadable => relay-unreadable;
  # unknown run id => no-relay-record; identity/window verification is the pure
  # drain_labeled_kick_attest. A positive is recorded durably like a scheduled one.
  if [[ "$run_id" =~ ^labeled-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]; then
    ts="${run_id#labeled-}"
    ts="${ts%-*}"
    run_iso="${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z"
    run_start="$(drain_ts_to_epoch "$run_iso")"
    if [[ -z "$run_start" ]]; then
      emit "$run_id" 0 "bad-run-timestamp" "" "" ""
      continue
    fi
    kick_ref="$(kick_ref_of "$run_id")"
    if [[ -z "$kick_ref" ]]; then
      emit "$run_id" 0 "no-kick-ref" "" "" ""
      continue
    fi
    set +e
    kick_json="$(kick_record_of "$kick_ref")"
    krc=$?
    set -e
    if [[ "$krc" -ne 0 ]]; then
      emit "$run_id" 0 "relay-unreadable" "" "" ""
      continue
    fi
    if [[ -z "$kick_json" ]]; then
      emit "$run_id" 0 "no-relay-record" "" "" ""
      continue
    fi
    verdict="$(drain_labeled_kick_attest "$run_start" "$(drain_c2_label)" "$kick_json" \
      "$(kick_rivals_of "$run_id" "$kick_ref")")"
    if [[ "$verdict" != attested$'\t'* ]]; then
      emit "$run_id" 0 "$verdict" "" "" ""
      continue
    fi
    kick_ts="${verdict#attested$'\t'}"
    # enqueue_ts carries the kick's platform-recorded creation time (the labeled
    # analogue of the scheduled path's enqueue timestamp); slot_offset stays null —
    # a labeled fire has no cron slot, which is the whole reason this path exists.
    emit "$run_id" 1 "kick-verified" "$kick_ts" "" ""
    if (( record == 1 )); then
      if [[ ! -f "$DRAIN_ATTESTATIONS" ]] || ! grep -qF -- "$run_id" "$DRAIN_ATTESTATIONS"; then
        mkdir -p "$(dirname "$DRAIN_ATTESTATIONS")"
        emit "$run_id" 1 "kick-verified" "$kick_ts" "" "" >>"$DRAIN_ATTESTATIONS"
      fi
    fi
    continue
  fi

  # 2b. run_id must otherwise be scheduled-kind and well-formed (manual-* and any
  # malformed id are not attestable fire kinds).
  if [[ ! "$run_id" =~ ^scheduled-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]; then
    emit "$run_id" 0 "not-scheduled-kind" "" "" ""
    continue
  fi

  # 3. run_start epoch from the embedded timestamp (YYYYMMDDTHHMMSSZ).
  ts="${run_id#scheduled-}"
  ts="${ts%-*}"
  run_iso="${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z"
  run_start="$(drain_ts_to_epoch "$run_iso")"
  if [[ -z "$run_start" ]]; then
    emit "$run_id" 0 "bad-run-timestamp" "" "" ""
    continue
  fi

  # 4-5. Originating-session join: candidate transcripts contain the run_id as a fixed
  # string AND carry a task-tagged enqueue record. Match the run against EVERY such
  # enqueue (across files AND across records within a file), counting each one whose
  # enqueue precedes the run start by 0..DRAIN_ATTEST_JOIN_WINDOW_S. Exactly one must
  # remain; >1 fails closed as ambiguous rather than picking one arbitrarily. Adjacent
  # 15-min fires stay single-candidate: slots are 900s apart (== the join window), but
  # a run starts >=~30s after ITS OWN enqueue, so the PREVIOUS slot's enqueue lands
  # >900s before the run start and falls out of the window (the next slot's enqueue is
  # after the run start, negative delta). The margin is thinner than the hourly grid's.
  origin_file="" origin_ts="" origin_epoch="" origin_count=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    while IFS= read -r ets; do
      [[ -n "$ets" ]] || continue
      eepoch="$(drain_ts_to_epoch "$ets")"
      [[ -n "$eepoch" ]] || continue
      delta=$((run_start - eepoch))
      if (( delta >= 0 && delta <= DRAIN_ATTEST_JOIN_WINDOW_S )); then
        origin_count=$((origin_count + 1))
        origin_file="$f"
        origin_ts="$ets"
        origin_epoch="$eepoch"
      fi
    done < <(drain_enqueue_ts_of "$f")
  done < <(grep -lF -- "$run_id" "$DRAIN_TRANSCRIPT_ROOT"/*/*.jsonl 2>/dev/null || true)

  if (( origin_count == 0 )); then
    emit "$run_id" 0 "no-origin-transcript" "" "" ""
    continue
  fi
  if (( origin_count > 1 )); then
    emit "$run_id" 0 "ambiguous-origin" "" "" ""
    continue
  fi

  # 6. Cron-slot alignment: seconds elapsed since the most recent slot on the grid
  # (period DRAIN_SLOT_PERIOD_MINUTES, anchored at minute DRAIN_SLOT_ANCHOR_MINUTE,
  # UTC-aligned). offset = ((epoch - anchor) mod period), non-negative.
  offset="$(drain_slot_offset_s "$origin_epoch")"
  if (( offset > DRAIN_FIRE_TOLERANCE_S )); then
    emit "$run_id" 0 "off-schedule" "$origin_ts" "$origin_file" "$offset"
    continue
  fi

  # 7. Attested.
  emit "$run_id" 1 "slot-aligned" "$origin_ts" "$origin_file" "$offset"
  if (( record == 1 )); then
    # Idempotent: never append a run_id already recorded (a positive shortcut above
    # would already have fired, but guard against any partially-written file). The
    # check-then-append is NOT concurrency-safe (no flock); this is acceptable because
    # its only writer, predicate-c2.sh, is a one-at-a-time operator reporter — a
    # documented assumption, not a race left unguarded.
    if [[ ! -f "$DRAIN_ATTESTATIONS" ]] || ! grep -qF -- "$run_id" "$DRAIN_ATTESTATIONS"; then
      mkdir -p "$(dirname "$DRAIN_ATTESTATIONS")"
      emit "$run_id" 1 "slot-aligned" "$origin_ts" "$origin_file" "$offset" \
        >>"$DRAIN_ATTESTATIONS"
    fi
  fi
done
