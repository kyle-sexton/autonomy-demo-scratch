#!/usr/bin/env bash
# Deterministic fire-origin attestation for drain runs. The Desktop task stamps
# fire_kind from a hardcoded --fire-kind flag baked into its SKILL.md, so a manual
# "Run now" from the app self-stamps as `scheduled`. The C2 promotion predicate must
# NOT trust that stamp; this verifier reconstructs fire origin from outer-session
# transcript evidence instead, and FAILS CLOSED at every step (any missing/ambiguous
# evidence => fire_attested=false with a specific reason).
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

  # 2. run_id must be scheduled-kind and well-formed.
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
