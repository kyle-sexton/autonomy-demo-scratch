#!/usr/bin/env bash
# Missed-fire detector (autonomy-ignition Phase 2 item 4). Deterministic, zero-token: an
# OS-scheduler-run script, no agent session required. Originally specced against the
# hourly cadence (plugins repo docs/topics/autonomy-ignition/PLAN.md); the 2026-07-22
# re-bind (scratch#43) moved the fire cadence to the 15-min slot grid, and this script's
# wiring was already deferred to Phase 4 — so it is re-specced here against the BOUND
# grid (DRAIN_SLOT_PERIOD_MINUTES / DRAIN_SLOT_ANCHOR_MINUTE, both in drain-common.sh),
# not a hardcoded hourly assumption. Re-spec + validation tracked as scratch#66; wiring
# into a live scheduled task/reconcile pass stays Phase 4 — this script is not invoked
# from drain-next.sh or any Desktop task.
#
# --- what "run history" means here -------------------------------------------------
# The original spec's "run history" is Desktop's own "Review history" panel, which is
# GUI-only: no on-disk run-history file is documented (code.claude.com/docs/en/
# desktop-scheduled-tasks, verified 2026-07-30) — not a scriptable signal. drain-runs.jsonl
# (DRAIN_RUN_STATE) is not a substitute either: drain-next.sh only appends a row when a
# fire finds work to claim (its no-work path prints and exits with no drain_record_run
# call), so a quiet queue would read as a run of missed fires that never happened.
#
# The one signal that IS scriptable and covers every genuine fire — work or no-work — is
# the task-tagged enqueue record attest-fire-origin.sh already mines from outer-session
# transcripts: the Desktop task starts one outer session per fire, and that session logs
# a <scheduled-task name="..."> enqueue record regardless of what the fire finds to do.
# This script reuses that exact primitive (drain_enqueue_ts_of, shared via drain-common.sh)
# instead of duplicating it.
#
# --- detection -----------------------------------------------------------------------
# For each grid slot in [--since, --until) whose tolerance deadline has already passed
# (slot + DRAIN_FIRE_TOLERANCE_S < until, strictly — an enqueue landing exactly AT the
# deadline is still on-time per attest-fire-origin.sh's own boundary), the slot is COVERED
# if any mined enqueue's drain_slot_offset_s resolves to it, else MISSED. Contiguous missed
# slots coalesce into ONE tracker item (a multi-hour outage is one event, not N) via the
# work-item-tracker seam drain-next.sh's reconcile preamble also uses.
#
# Dedup identity is the FIRST missed slot of the coalesced run only (drain_missed_fire_title),
# never the range end — the range end grows on every re-invocation of an ongoing outage,
# so keying on the full range would file an overlapping duplicate each time instead of
# matching the item already open.
#
# That first slot names the INCIDENT only while the outage starts inside the scan window.
# An outage older than the lookback is truncated by the window's LEADING edge, so its anchor
# would slide forward a slot per invocation and miss the open item just as surely. A leading
# range abutting the window's first grid slot was therefore cut by that edge rather than by a
# covered slot, and is extended backwards through consecutively-missed slots to the first
# covered slot before the title is built; coverage is mined from every transcript, unbounded
# by the window, so those earlier slots are judged against the same evidence. Interior ranges
# already sit between covered slots on both sides and are left alone.
#
# RESIDUAL: dedup checks only OPEN tracker items (this
# repo's standing reconcile convention); if a filed item is closed while its gap is still
# inside the lookback window, the next run re-files it. Accepted for the same reason the
# other reconcile kinds accept it — a human closes the item once resolved, and a detector
# re-flagging a window a human already dismissed is a rarer, louder case than the routine
# per-fire reconcile kinds it shares the convention with.
#
# `--dry-run` performs NO side effects (matches drain-next.sh's contract) and needs no
# gh auth: it only reads local transcripts and prints, per missed range, the exact title
# and body the live path would file. Only the live path (dedup lookup + filing) touches
# the network, via the work-item-tracker adapter seam.
#
# CADENCE-FLIP FLOOR: a --since reaching before DRAIN_SLOT_GRID_MERGED_UTC would judge
# pre-flip (hourly-cadence) fires against the 15-min grid and manufacture ~3 false missed
# slots per hour (see the constant's comment in drain-common.sh for why this direction is
# not symmetric with attest-fire-origin.sh's hourly->15-min transition case). --since is
# clamped to that floor with a WARN, never silently judged past it.
#
# ACTIVATION FLOOR: that merge is only the earliest the grid COULD have been live. Flipping
# the Desktop task is a separate operator action with no on-disk record, so the interval
# between the merge and the real flip still ran the hourly cadence, and judging it against
# the 15-min grid fabricates the same ~3 false slots per hour. The flip is therefore proven
# from evidence rather than assumed: the prior grid was period 60 / anchor 0, so a covered
# slot at :15/:30/:45 is a fire the hourly cadence could not have produced and proves the
# 15-min grid was already live. The earliest such slot at or after the merge floor is the
# activation boundary. An UNCOVERED slot before it is UNJUDGEABLE — there a missed fire and
# a not-yet-flipped schedule are indistinguishable — and is skipped rather than reported,
# while a covered slot needs no cadence proof and is unaffected. With no off-hour slot
# anywhere in the scanned transcripts, activation is unproven entirely and every uncovered
# slot is unjudgeable: fail closed and say so, never report fabricated gaps.
#
# Usage: detect-missed-fire.sh [--dry-run] [--since <iso8601>] [--until <iso8601>]
#   --since default: 24h before --until. Not a full historical audit — bounded by both
#           the cadence-flip floor above and outer-session transcript retention (once a
#           transcript is garbage-collected, this script has no record of the fire it
#           logged; attest-fire-origin.sh's --record durability has no missed-fire analog).
#   --until default: now.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

ADAPTER_DIR="${DRAIN_REPO_ROOT}/tools/work-item-tracker/adapters/github"

dry_run=false
since_arg="" until_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --since)
      since_arg="${2:?--since needs a value}"
      shift 2
      ;;
    --until)
      until_arg="${2:?--until needs a value}"
      shift 2
      ;;
    *)
      echo "detect-missed-fire.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

until_iso="${until_arg:-$(drain_iso_now)}"
until_epoch="$(drain_ts_to_epoch "$until_iso")"
[[ -n "$until_epoch" ]] || {
  echo "detect-missed-fire.sh: bad --until timestamp: $until_iso" >&2
  exit 2
}

if [[ -n "$since_arg" ]]; then
  since_epoch="$(drain_ts_to_epoch "$since_arg")"
  [[ -n "$since_epoch" ]] || {
    echo "detect-missed-fire.sh: bad --since timestamp: $since_arg" >&2
    exit 2
  }
else
  since_epoch=$((until_epoch - 24 * 3600))
fi

floor_epoch="$(drain_ts_to_epoch "$DRAIN_SLOT_GRID_MERGED_UTC")"
if (( since_epoch < floor_epoch )); then
  echo "detect-missed-fire.sh: WARN --since predates the 15-min grid floor ($DRAIN_SLOT_GRID_MERGED_UTC); clamping (see the cadence-flip floor note in this script's header)" >&2
  since_epoch="$floor_epoch"
fi

if (( since_epoch >= until_epoch )); then
  echo "detect-missed-fire.sh: nothing to scan (since >= until after clamping)"
  exit 0
fi

# --- 1. mine every task-tagged enqueue's covered slot, across all outer transcripts ---
period_sec=$((DRAIN_SLOT_PERIOD_MINUTES * 60))
anchor_sec=$((DRAIN_SLOT_ANCHOR_MINUTE * 60))
# The cadence this grid replaced (drain-common.sh: period 60, anchor 0). A covered slot off
# THIS boundary could not have come from it, which is the activation proof step 1b mines.
prior_period_sec=3600
# Covered slots are an associative array, not a temp file: membership is tested once per grid
# slot in the window AND once per slot the leading-range extension walks back over, so one
# `grep` subprocess per test dominated the runtime over a multi-day range.
declare -A covered=()
missed_file="$(mktemp)"
ordered_file="$(mktemp)"
trap 'rm -f "$missed_file" "$ordered_file"' EXIT
for f in "$DRAIN_TRANSCRIPT_ROOT"/*/*.jsonl; do
  [[ -f "$f" ]] || continue
  while IFS= read -r ets; do
    [[ -n "$ets" ]] || continue
    eepoch="$(drain_ts_to_epoch "$ets")"
    [[ -n "$eepoch" ]] || continue
    off="$(drain_slot_offset_s "$eepoch")"
    if (( off <= DRAIN_FIRE_TOLERANCE_S )); then
      covered[$((eepoch - off))]=1
    fi
  done < <(drain_enqueue_ts_of "$f")
done

# --- 1b. prove when the 15-min grid actually went live (ACTIVATION FLOOR above) -------
# Empty result = activation unproven, which leaves every uncovered slot unjudgeable.
activation_epoch=""
for cslot in "${!covered[@]}"; do
  (( cslot >= floor_epoch )) || continue
  (( (cslot - anchor_sec) % prior_period_sec != 0 )) || continue
  if [[ -z "$activation_epoch" ]] || (( cslot < activation_epoch )); then
    activation_epoch="$cslot"
  fi
done

# --- 2. walk the grid over [since, until), skipping any slot not yet judgeable --------
rem=$(( (since_epoch - anchor_sec) % period_sec ))
(( rem < 0 )) && rem=$((rem + period_sec))
if (( rem == 0 )); then
  slot=$since_epoch
else
  slot=$((since_epoch + period_sec - rem))
fi
first_slot=$slot

unjudgeable_count=0
while (( slot < until_epoch )); do
  if (( slot + DRAIN_FIRE_TOLERANCE_S < until_epoch )); then
    if [[ -n "${covered[$slot]:-}" ]]; then
      : # covered
    elif [[ -n "$activation_epoch" ]] && (( slot >= activation_epoch )); then
      echo "$slot" >>"$missed_file"
    else
      unjudgeable_count=$((unjudgeable_count + 1))
    fi
  fi
  slot=$((slot + period_sec))
done

if (( unjudgeable_count > 0 )); then
  if [[ -n "$activation_epoch" ]]; then
    unjudgeable_why="they precede the grid's proven activation ($(date -u -d "@$activation_epoch" +%Y-%m-%dT%H:%M:%SZ))"
  else
    unjudgeable_why="no off-hour enqueue exists in any scanned transcript, so activation is unproven entirely"
  fi
  echo "detect-missed-fire.sh: WARN $unjudgeable_count uncovered slot(s) left UNJUDGED — $unjudgeable_why; there a missed fire is indistinguishable from the pre-flip hourly cadence (see the activation-floor note in this script's header)" >&2
fi

if [[ ! -s "$missed_file" ]]; then
  if (( unjudgeable_count > 0 )); then
    echo "cadence-ambiguous: $unjudgeable_count slot(s) not judgeable (15-min grid activation unproven); no missed fire among the slots that were"
  else
    echo "no-gaps"
  fi
  exit 0
fi

# --- 2b. extend a window-truncated leading range to the incident's own first slot -----
# See the dedup-identity note in this script's header. activation_epoch is necessarily set
# here: a slot is only recorded missed once activation is proven.
first_missed="$(head -n 1 "$missed_file")"
if (( first_missed == first_slot )); then
  probe=$((first_missed - period_sec))
  while (( probe >= activation_epoch )) && [[ -z "${covered[$probe]:-}" ]]; do
    echo "$probe" >>"$missed_file"
    probe=$((probe - period_sec))
  done
fi
sort -n "$missed_file" >"$ordered_file"

# --- 3. coalesce contiguous missed slots (period_sec apart) into ranges --------------
range_first="" range_last="" range_count=0
flush_range() {
  [[ -n "$range_first" ]] || return 0
  local first_iso last_iso title body
  first_iso="$(date -u -d "@$range_first" +%Y-%m-%dT%H:%M:%SZ)"
  last_iso="$(date -u -d "@$range_last" +%Y-%m-%dT%H:%M:%SZ)"
  title="$(drain_missed_fire_title "$first_iso")"
  body="$(printf 'Automated missed-fire detection (needs human action).\n\n- grid: every %sm, anchored at :%02d\n- missed slots: %s..%s (%d slot(s))\n- tolerance: %ss past each slot\n\nNo task-tagged enqueue record was found within tolerance of any slot in this range across the outer-session transcripts scanned. This may be a genuine scheduler outage (machine asleep, app closed, Windows Update) or transcripts for a real fire already garbage-collected. A human verifies which.' \
    "$DRAIN_SLOT_PERIOD_MINUTES" "$DRAIN_SLOT_ANCHOR_MINUTE" "$first_iso" "$last_iso" "$range_count" "$DRAIN_FIRE_TOLERANCE_S")"

  if [[ "$dry_run" == "true" ]]; then
    echo "missed-fire(dry): would file '$title'"
    printf '%s\n' "$body" | sed 's/^/  | /'
  else
    if drain_open_reconcile_titles_missed_fire | grep -qxF "$title"; then
      echo "missed-fire: '$title' already open, skipping"
    else
      "$ADAPTER_DIR/create-item.sh" --title "$title" --body "$body" >/dev/null \
        && echo "missed-fire: filed '$title'" \
        || echo "detect-missed-fire.sh: WARN could not file '$title'" >&2
    fi
  fi
}

# drain_open_reconcile_titles_missed_fire — same open-titles listing drain-next.sh's
# reconcile preamble uses for dedup (network read; local wrapper here only to keep it
# out of the dry-run path, which must stay gh-free).
drain_open_reconcile_titles_missed_fire() {
  "$ADAPTER_DIR/list-items.sh" --state open 2>/dev/null \
    | jq -r '.items[]?.title' 2>/dev/null | tr -d '\r' || true
}

while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  if [[ -z "$range_first" ]]; then
    range_first="$s"
    range_last="$s"
    range_count=1
  elif (( s == range_last + period_sec )); then
    range_last="$s"
    range_count=$((range_count + 1))
  else
    flush_range
    range_first="$s"
    range_last="$s"
    range_count=1
  fi
done <"$ordered_file"
flush_range
