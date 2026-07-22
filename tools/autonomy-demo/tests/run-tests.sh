#!/usr/bin/env bash
# Deterministic behavioural tests for the drain scripts, exercised by the gate
# (.github/workflows/gate.yml) as the substance step beyond lint. Pure bash +
# jq + coreutils + git only: NO package installs, NO network, NO duckdb — every
# tool here is preinstalled on ubuntu-latest GitHub runners.
#
# Coverage:
#   1. candidate-filter.jq — the REAL production eligibility filter (shared with
#      drain-next.sh via drain_select_candidates), against a fixture item set.
#   2. CR-stripping regression — drain_select_candidates output is CR-free (guards
#      the jq.exe-CRLF contamination that leaked into item_url on Windows).
#   3. drain_revert_sha — revert detection over a throwaway git history, incl. the
#      fail-closed contract (non-zero, not empty, when the range is unreadable).
#   4. drain_merged_but_open_flags — the double-drain guard's pure decision:
#      flag / don't-flag / dedup.
#   5. pure drain-common.sh helpers (drain_class_from_label, drain_item_url).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../drain-common.sh
source "$TEST_DIR/../drain-common.sh"
FIXTURES="$TEST_DIR/fixtures"

tests_run=0
tests_failed=0

pass() {
  printf 'ok - %s\n' "$1"
}
faild() {
  tests_failed=$((tests_failed + 1))
  printf 'not ok - %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '  # %s\n' "$2"
  return 0
}
assert_eq() { # <name> <actual> <expected>
  tests_run=$((tests_run + 1))
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    faild "$1" "expected=[$3] actual=[$2]"
  fi
}
assert_absent() { # <name> <haystack> <needle-regex>
  tests_run=$((tests_run + 1))
  if printf '%s\n' "$2" | grep -qE "$3"; then
    faild "$1" "unexpected match for /$3/"
  else
    pass "$1"
  fi
}

# --- 1. candidate eligibility + ordering ------------------------------------
selected="$(drain_select_candidates 'work-class: c2' <"$FIXTURES/items-eligible.json")"
expected="$(printf 'github:o/r#9\thttps://github.com/o/r/issues/9\ngithub:o/r#10\thttps://github.com/o/r/issues/10')"
assert_eq "candidate filter: labelled+unblocked+unassigned selected, sorted by issue number" \
  "$selected" "$expected"
assert_absent "candidate filter: unlabelled #11 rejected" "$selected" 'issues/11$'
assert_absent "candidate filter: assigned #12 rejected" "$selected" 'issues/12$'
assert_absent "candidate filter: blocked #13 rejected" "$selected" 'issues/13$'

# --- 2. CR-stripping regression ---------------------------------------------
# jq.exe under Windows text-mode stdout appends a CR to every output line; without
# the trailing `tr -d '\r'` in drain_select_candidates it rides into the last
# @tsv field and corrupts item_url (historically "...issues/10\r"). Assert the
# helper's output carries no CR byte. On Linux jq emits LF so this asserts the
# contract; on Windows it is a live regression guard on the strip.
cr_count="$(drain_select_candidates 'work-class: c2' <"$FIXTURES/items-eligible.json" \
  | tr -cd '\r' | wc -c | tr -d ' ')"
assert_eq "candidate output is CR-free (jq.exe CRLF stripped)" "$cr_count" "0"

# --- 3. revert detection over a throwaway git history -----------------------
revrepo="$(mktemp -d)"
trap 'rm -rf "$revrepo"' EXIT
gitc() { git -C "$revrepo" -c user.email=t@t.local -c user.name=drain-test "$@"; }
git -C "$revrepo" init -q
gitc commit -q --allow-empty -m "base"
base_sha="$(git -C "$revrepo" rev-parse HEAD)"
gitc commit -q --allow-empty -m "merge drain PR"
merge_sha="$(git -C "$revrepo" rev-parse HEAD)"
gitc commit -q --allow-empty -m "unrelated later work"
gitc commit -q --allow-empty -m "Revert the drain PR" -m "This reverts commit ${merge_sha}."
revert_sha="$(git -C "$revrepo" rev-parse HEAD)"

assert_eq "drain_revert_sha: detects the reverting commit for a reverted merge" \
  "$(drain_revert_sha "$revrepo" "$merge_sha" HEAD)" "$revert_sha"
assert_eq "drain_revert_sha: empty for an unreverted (but ancestor) merge" \
  "$(drain_revert_sha "$revrepo" "$base_sha" HEAD)" ""
assert_eq "drain_revert_sha: empty for an empty merge_sha" \
  "$(drain_revert_sha "$revrepo" "" HEAD)" ""
# Fail-closed: an unreadable range (unknown sha / unfetched ref) must return
# non-zero, NOT an empty string indistinguishable from "confirmed unreverted".
tests_run=$((tests_run + 1))
if drain_revert_sha "$revrepo" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" HEAD >/dev/null 2>&1; then
  faild "drain_revert_sha: FAILS CLOSED (non-zero) when the range is unreadable"
else
  pass "drain_revert_sha: FAILS CLOSED (non-zero) when the range is unreadable"
fi

# --- 4. merged-but-open decision (double-drain guard) -----------------------
# stdin: merged drain PRs "<issue>\t<pr>\t<run_id>". args: open C2 issue numbers,
# and already-open reconcile titles for dedup.
mbo_merged="$(printf '6\t8\tscheduled-run-6\n99\t50\tscheduled-run-99')"
mbo_open="$(printf '6\n7')" # 6,7 open+C2; 7 has no merged PR; 99 is merged but not open
flags="$(printf '%s\n' "$mbo_merged" | drain_merged_but_open_flags "$mbo_open" "")"
assert_eq "merged-but-open: open+C2 issue with a merged drain PR is flagged (7 and 99 are not)" \
  "$flags" "$(printf '6\t8\tscheduled-run-6')"
mbo_existing="$(drain_reconcile_title 'merged-but-open' 'scheduled-run-6' '6')"
flags_dedup="$(printf '%s\n' "$mbo_merged" | drain_merged_but_open_flags "$mbo_open" "$mbo_existing")"
assert_eq "merged-but-open: already-filed title is not re-flagged (idempotent dedup)" \
  "$flags_dedup" ""

# --- 5. pure drain-common.sh helpers ----------------------------------------
assert_eq "drain_class_from_label: c2 -> C2" "$(drain_class_from_label 'work-class: c2')" "C2"
assert_eq "drain_class_from_label: c4 -> C4" "$(drain_class_from_label 'work-class: c4')" "C4"
assert_eq "drain_class_from_label: no token -> C2 default" "$(drain_class_from_label 'plain-label')" "C2"
assert_eq "drain_item_url: builds the issue URL" "$(drain_item_url 'o/r' 42)" "https://github.com/o/r/issues/42"
# Work-item lease TTL: 1h stopgap (drain-next.sh passes DRAIN_LEASE_TTL_HOURS to the
# tracker's claim.sh, which accepts whole hours only). Guards the value against drift.
assert_eq "lease TTL: DRAIN_LEASE_TTL_HOURS is the 1h stopgap" "$DRAIN_LEASE_TTL_HOURS" "1"

# --- 6. attest-fire-origin.sh -----------------------------------------------
# Fire-origin attestation from outer-session transcript evidence. Env points the
# transcript root, artifact dir, and attestations file at a throwaway tree; synthetic
# transcripts match the real record shape (fact 1): an enqueue queue-operation first
# line carrying the scheduled-task tag, then a filler line mentioning the run_id.
ATTEST="$TEST_DIR/../attest-fire-origin.sh"
attest_tmp="$(mktemp -d)"
trap 'rm -rf "$revrepo" "$attest_tmp"' EXIT
export DRAIN_TRANSCRIPT_ROOT="$attest_tmp/projects"
export DRAIN_ARTIFACT_DIR="$attest_tmp/artifacts"
export DRAIN_ATTESTATIONS="$attest_tmp/artifacts/fire-attestations.jsonl"
proj="$DRAIN_TRANSCRIPT_ROOT/demo-slug"
mkdir -p "$proj" "$DRAIN_ARTIFACT_DIR"

enq_line() { # <enqueue_ts> — one task-tagged enqueue queue-operation record
  jq -cn --arg ts "$1" --arg name "$DRAIN_SCHEDULED_TASK_NAME" \
    '{content: ("<scheduled-task name=\"" + $name + "\" file=\"C:\\x\\SKILL.md\">\nbody\n</scheduled-task>"),
      operation: "enqueue", sessionId: "sess", timestamp: $ts, type: "queue-operation"}'
}
fil_line() { # <run_id> — a filler record mentioning the run_id (as production logs it)
  jq -cn --arg rid "$1" '{content: ("drain output run_id=" + $rid), type: "assistant"}'
}
mk_transcript() { # <file> <enqueue_ts> <run_id>
  { enq_line "$2"; fil_line "$3"; } >"$1"
}
att_reason() { jq -r '.reason' <<<"$1"; }
att_flag() { jq -r '.fire_attested' <<<"$1"; }
att_ets() { jq -r '.enqueue_ts' <<<"$1"; }
att_off() { jq -r '.slot_offset_s' <<<"$1"; }

# 1. aligned: enqueue :05:25, run start :06:01 (within join window, within tolerance).
mk_transcript "$proj/c1.jsonl" "2026-07-21T10:05:25.000Z" "scheduled-20260721T100601Z-aaaaaaaa"
a1="$("$ATTEST" scheduled-20260721T100601Z-aaaaaaaa)"
assert_eq "attest: aligned fire attested" "$(att_flag "$a1")" "true"
assert_eq "attest: aligned reason slot-aligned" "$(att_reason "$a1")" "slot-aligned"

# 2. off-schedule manual: origin transcript present, but the enqueue lands between
# slots (:08:30 = 510s past the :00 slot, beyond the 480s tolerance).
mk_transcript "$proj/c2.jsonl" "2026-07-21T10:08:30.000Z" "scheduled-20260721T100906Z-bbbbbbbb"
a2="$("$ATTEST" scheduled-20260721T100906Z-bbbbbbbb)"
assert_eq "attest: off-schedule not attested" "$(att_flag "$a2")" "false"
assert_eq "attest: off-schedule reason" "$(att_reason "$a2")" "off-schedule"

# 3. reconcile-only mention: the only transcript mentioning the run_id was enqueued
# hours AFTER the run start (negative delta) — not the originating session.
mk_transcript "$proj/c3.jsonl" "2026-07-21T15:05:00.000Z" "scheduled-20260721T120000Z-33333333"
a3="$("$ATTEST" scheduled-20260721T120000Z-33333333)"
assert_eq "attest: reconcile-only mention not attested" "$(att_flag "$a3")" "false"
assert_eq "attest: reconcile-only reason no-origin-transcript" "$(att_reason "$a3")" "no-origin-transcript"

# 4. missing transcript entirely.
a4="$("$ATTEST" scheduled-20260721T130000Z-44444444)"
assert_eq "attest: missing transcript not attested" "$(att_flag "$a4")" "false"
assert_eq "attest: missing transcript reason no-origin-transcript" "$(att_reason "$a4")" "no-origin-transcript"

# 5. ambiguous: run_id present in TWO transcripts both enqueued within the join window.
mk_transcript "$proj/c5a.jsonl" "2026-07-21T14:05:20.000Z" "scheduled-20260721T140601Z-55555555"
mk_transcript "$proj/c5b.jsonl" "2026-07-21T14:05:25.000Z" "scheduled-20260721T140601Z-55555555"
a5="$("$ATTEST" scheduled-20260721T140601Z-55555555)"
assert_eq "attest: ambiguous origin not attested" "$(att_flag "$a5")" "false"
assert_eq "attest: ambiguous reason" "$(att_reason "$a5")" "ambiguous-origin"

# 6. not-scheduled kind (manual-*): rejected before any transcript scan.
a6="$("$ATTEST" manual-20260721T104250Z-cccccccc)"
assert_eq "attest: manual kind not attested" "$(att_flag "$a6")" "false"
assert_eq "attest: manual kind reason not-scheduled-kind" "$(att_reason "$a6")" "not-scheduled-kind"

# 7. durability: --record case 1, delete its transcript, re-run --record -> still
# attested from the recorded positive; the attestations file holds exactly one line
# for the run_id across both records (idempotent append).
rid7="scheduled-20260721T100601Z-aaaaaaaa"
"$ATTEST" --record "$rid7" >/dev/null
rm -f "$proj/c1.jsonl"
a7="$("$ATTEST" --record "$rid7")"
assert_eq "attest: durability survives transcript GC (attested)" "$(att_flag "$a7")" "true"
assert_eq "attest: durability reason recorded" "$(att_reason "$a7")" "recorded"
assert_eq "attest: recorded exactly once (idempotent append)" \
  "$(grep -cF "$rid7" "$DRAIN_ATTESTATIONS")" "1"

# 8. CR-carrying run_id argument (jq.exe CRLF boundary): a trailing CR must be
# stripped so a real run_id attests identically to its clean form, and the emitted
# run_id field must itself be CR-free. Reuse case 1's transcript (recreate it, since
# case 7 deleted it) and pass the arg with a literal trailing CR.
mk_transcript "$proj/c1.jsonl" "2026-07-21T10:05:25.000Z" "scheduled-20260721T100601Z-aaaaaaaa"
a8="$("$ATTEST" $'scheduled-20260721T100601Z-aaaaaaaa\r')"
assert_eq "attest: CR-carrying run_id attests as clean form" "$(att_flag "$a8")" "true"
# Assert no CR is embedded in the emitted run_id VALUE. jq's contains() inspects the
# string; the `tr -d '\r'` strips jq.exe's OWN line-ending CR on Windows at the
# measurement boundary (a raw byte count would instead pick that up and false-fail).
assert_eq "attest: CR-carrying run_id emits CR-free run_id" \
  "$(jq -r '.run_id | contains("\r")' <<<"$a8" | tr -d '\r')" "false"

# 9. Multiple task-tagged enqueues in ONE long-lived transcript. Each run_id must
# resolve against ITS OWN enqueue record, not merely the file's first — otherwise a
# later manual fire would inherit the earlier scheduled fire's slot alignment (false
# positive) or a later legit fire would fall outside the window (false negative).
# One file logs two fires: enqueue :05:25 spawning run A (start :06:01, aligned) and
# enqueue :23:30 spawning run B (start :24:06, off-schedule — 510s past the :15 slot).
# Run B's start is >900s after the :05:25 enqueue, so ONLY its own :23:30 enqueue is
# in-window (a single candidate), isolating the per-record resolution under test.
runA="scheduled-20260721T100601Z-a1a1a1a1"
runB="scheduled-20260721T102406Z-b2b2b2b2"
{ enq_line "2026-07-21T10:05:25.000Z"; fil_line "$runA"
  enq_line "2026-07-21T10:23:30.000Z"; fil_line "$runB"; } >"$proj/multi.jsonl"
m1="$("$ATTEST" "$runA")"
assert_eq "attest: multi-enqueue run A resolves to its own enqueue (aligned)" "$(att_flag "$m1")" "true"
assert_eq "attest: multi-enqueue run A reason slot-aligned" "$(att_reason "$m1")" "slot-aligned"
assert_eq "attest: multi-enqueue run A enqueue_ts is :05:25 (not merely first)" \
  "$(att_ets "$m1")" "2026-07-21T10:05:25.000Z"
m2="$("$ATTEST" "$runB")"
assert_eq "attest: multi-enqueue run B resolves to its OWN later enqueue (not first)" \
  "$(att_ets "$m2")" "2026-07-21T10:23:30.000Z"
assert_eq "attest: multi-enqueue run B off-schedule" "$(att_reason "$m2")" "off-schedule"
assert_eq "attest: multi-enqueue run B offset 510" "$(att_off "$m2")" "510"

# 9c. Two in-window enqueues both matching a single run_id -> ambiguous (fail closed;
# never pick one arbitrarily).
runC="scheduled-20260721T100601Z-c3c3c3c3"
{ enq_line "2026-07-21T10:05:20.000Z"; enq_line "2026-07-21T10:05:25.000Z"; fil_line "$runC"; } \
  >"$proj/multi-ambiguous.jsonl"
m3="$("$ATTEST" "$runC")"
assert_eq "attest: two in-window enqueues for one run_id -> ambiguous" \
  "$(att_reason "$m3")" "ambiguous-origin"
assert_eq "attest: ambiguous multi-enqueue not attested" "$(att_flag "$m3")" "false"

# --- 10. slot grid (period 15 / anchor 0) -----------------------------------
# The scheduler moved from hourly to every-15-min. attest-fire-origin now measures the
# enqueue offset from the nearest preceding grid slot (:00/:15/:30/:45), not the top of
# the hour, against DRAIN_FIRE_TOLERANCE_S (480s). Offset N means enqueue at slot + N.

# aligned at a NON-:00 slot (proves anchor-relative offset, not hour-relative):
# enqueue :20:25 = 325s past the :15 slot -> aligned, matching genuine dispatch delay.
mk_transcript "$proj/g-aligned.jsonl" "2026-07-21T11:20:25.000Z" "scheduled-20260721T112101Z-9a000001"
g1="$("$ATTEST" scheduled-20260721T112101Z-9a000001)"
assert_eq "slot grid: aligned within tolerance of the :15 slot" "$(att_flag "$g1")" "true"
assert_eq "slot grid: aligned offset 325 from the :15 slot (not the hour)" "$(att_off "$g1")" "325"

# boundary: enqueue exactly DRAIN_FIRE_TOLERANCE_S (480s) past a slot -> still aligned
# (the reject condition is offset > tolerance). :38:00 = 480s past the :30 slot.
mk_transcript "$proj/g-boundary.jsonl" "2026-07-21T11:38:00.000Z" "scheduled-20260721T113836Z-9a000002"
g2="$("$ATTEST" scheduled-20260721T113836Z-9a000002)"
assert_eq "slot grid: enqueue exactly +480s (boundary) still attests" "$(att_flag "$g2")" "true"
assert_eq "slot grid: boundary offset 480" "$(att_off "$g2")" "480"

# misaligned: enqueue 510s past the :45 slot (:53:30) -> off-schedule (510 > 480).
mk_transcript "$proj/g-off.jsonl" "2026-07-21T11:53:30.000Z" "scheduled-20260721T115406Z-9a000003"
g3="$("$ATTEST" scheduled-20260721T115406Z-9a000003)"
assert_eq "slot grid: enqueue +510s past the :45 slot is off-schedule" "$(att_flag "$g3")" "false"
assert_eq "slot grid: off-schedule offset 510" "$(att_off "$g3")" "510"

# hourly->15-min transition: an OLD-cadence hourly enqueue (+330s past the hour) still
# aligns under period-15/anchor-0 (the hour boundary is itself a slot), so runs that
# straddle the cadence change need no special-casing.
mk_transcript "$proj/g-hourly.jsonl" "2026-07-21T11:05:30.000Z" "scheduled-20260721T110606Z-9a000004"
g4="$("$ATTEST" scheduled-20260721T110606Z-9a000004)"
assert_eq "slot grid: old hourly enqueue (+330s) still aligns under 15-min grid" "$(att_flag "$g4")" "true"
assert_eq "slot grid: hourly-transition offset 330 from the :00 slot" "$(att_off "$g4")" "330"

# adjacent-slot disambiguation at minimal margin — pins the migration's safety argument
# that 15-min fires stay single-candidate even though the join window (900s) now EQUALS
# the slot period (900s). Two GENUINE aligned enqueues one slot apart in ONE transcript:
# :05:00 -> run A start :05:36 (slot :00), :20:00 -> run B start :20:36 (slot :15). Run B
# must resolve to its OWN :20:00 enqueue (single-candidate, aligned), NOT ambiguous: the
# :05:00 enqueue sits 900+36=936s before run B's start, just outside the 900s window.
# This is the >=~30s enqueue->start floor the ~915s worst-case reasoning rests on; if it
# regressed, run B would read ambiguous-origin (fail-closed EXCLUSION) and this flips.
runX="scheduled-20260721T110536Z-c0c0c0c0"
runY="scheduled-20260721T112036Z-d0d0d0d0"
{ enq_line "2026-07-21T11:05:00.000Z"; fil_line "$runX"
  enq_line "2026-07-21T11:20:00.000Z"; fil_line "$runY"; } >"$proj/adjacent.jsonl"
adjX="$("$ATTEST" "$runX")"
assert_eq "slot grid: adjacent-slot run A aligned single-candidate" "$(att_reason "$adjX")" "slot-aligned"
adjY="$("$ATTEST" "$runY")"
assert_eq "slot grid: adjacent-slot run B single-candidate/aligned (NOT ambiguous)" \
  "$(att_reason "$adjY")" "slot-aligned"
assert_eq "slot grid: adjacent-slot run B attested" "$(att_flag "$adjY")" "true"
assert_eq "slot grid: adjacent-slot run B resolves to its OWN :20:00 enqueue" \
  "$(att_ets "$adjY")" "2026-07-21T11:20:00.000Z"
assert_eq "slot grid: adjacent-slot run B offset 300 from the :15 slot" "$(att_off "$adjY")" "300"

# --- 11. merge-age maturity guard (drain_merge_is_mature) --------------------
# The C2 >=20-completions threshold counts only completions whose PR merged >=48h
# before evaluation time (predicate-c2.sh enriches each join row via this pure helper;
# the SQL just counts mature rows). Pure decision, unit-tested off a fixed clock so no
# duckdb is needed. Boundary is inclusive (>= 48h counts).
now_ref=1000000000
mature_iso="$(date -u -d "@$((now_ref - 72 * 3600))" +%Y-%m-%dT%H:%M:%SZ)"
bound_iso="$(date -u -d "@$((now_ref - 48 * 3600))" +%Y-%m-%dT%H:%M:%SZ)"
just_young_iso="$(date -u -d "@$((now_ref - 48 * 3600 + 60))" +%Y-%m-%dT%H:%M:%SZ)"
young_iso="$(date -u -d "@$((now_ref - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
# timezone marker: a naive string (no Z / offset) fails CLOSED — GNU date would parse it
# in local TZ and mis-judge maturity by the local offset. An explicit +hh:mm is accepted.
naive_iso="$(date -u -d "@$((now_ref - 72 * 3600))" +%Y-%m-%dT%H:%M:%S)"
offset_iso="$(date -u -d "@$((now_ref - 72 * 3600))" +%Y-%m-%dT%H:%M:%S+00:00)"
assert_eq "merge maturity: 72h-old merge counts (mature)" \
  "$(drain_merge_is_mature "$mature_iso" "$now_ref")" "true"
assert_eq "merge maturity: exactly 48h-old merge counts (boundary, inclusive)" \
  "$(drain_merge_is_mature "$bound_iso" "$now_ref")" "true"
assert_eq "merge maturity: 47h59m-old merge does not count (young)" \
  "$(drain_merge_is_mature "$just_young_iso" "$now_ref")" "false"
assert_eq "merge maturity: 1h-old merge does not count (young)" \
  "$(drain_merge_is_mature "$young_iso" "$now_ref")" "false"
assert_eq "merge maturity: unmerged (empty merged_at) does not count" \
  "$(drain_merge_is_mature "" "$now_ref")" "false"
assert_eq "merge maturity: null merged_at does not count" \
  "$(drain_merge_is_mature "null" "$now_ref")" "false"
assert_eq "merge maturity: timezone-naive timestamp fails closed (not mature)" \
  "$(drain_merge_is_mature "$naive_iso" "$now_ref")" "false"
assert_eq "merge maturity: explicit +00:00 offset accepted (mature)" \
  "$(drain_merge_is_mature "$offset_iso" "$now_ref")" "true"

# --- 12. post-merge demotion watcher (watch-demotion.sh) --------------------
# Pure, network-free coverage of the watcher's decision helpers (hosted in
# drain-common.sh). The network orchestration (gh pr view / check-run API, merge-commit-
# first gate resolution) is not unit-tested here — no gh/network in this tier — but the
# load-bearing decisions are: the gate verdict, complete-run enumeration + its fail-closed
# contract, revert detection (section 3 above, reused directly by Check B), and the
# idempotency key.

# 12a. drain_gate_verdict — success is the ONLY clean conclusion; every non-success enum
# value AND an empty (no gate check-run on a merged PR = bypass) are contrary; an
# unrecognized token is indeterminate (fail closed).
assert_eq "gate verdict: success -> clean" "$(drain_gate_verdict success)" "clean"
assert_eq "gate verdict: failure -> contrary" "$(drain_gate_verdict failure)" "contrary"
assert_eq "gate verdict: cancelled -> contrary" "$(drain_gate_verdict cancelled)" "contrary"
assert_eq "gate verdict: timed_out -> contrary" "$(drain_gate_verdict timed_out)" "contrary"
assert_eq "gate verdict: action_required -> contrary" "$(drain_gate_verdict action_required)" "contrary"
assert_eq "gate verdict: stale -> contrary" "$(drain_gate_verdict stale)" "contrary"
assert_eq "gate verdict: skipped -> contrary" "$(drain_gate_verdict skipped)" "contrary"
assert_eq "gate verdict: neutral -> contrary" "$(drain_gate_verdict neutral)" "contrary"
assert_eq "gate verdict: startup_failure -> contrary" "$(drain_gate_verdict startup_failure)" "contrary"
assert_eq "gate verdict: empty (no gate check-run on merged PR) -> contrary" "$(drain_gate_verdict '')" "contrary"
assert_eq "gate verdict: unrecognized token -> indeterminate (fail closed)" \
  "$(drain_gate_verdict some_new_conclusion)" "indeterminate"

# 12b. drain_complete_runs — last-status-per-run_id, filtered to complete. The fixture has
# run A (dispatched then complete: object-merged so the complete row's pr_url survives),
# run B (claimed only: excluded), run C (complete). Expect [A, C] with A carrying pull/1.
complete="$(drain_complete_runs "$FIXTURES/drain-runs-sample.jsonl")"
assert_eq "complete runs: only complete run_ids, in insertion order" \
  "$(jq -r '[.[].run_id] | join(",")' <<<"$complete")" "A,C"
assert_eq "complete runs: last-status merge keeps run A's terminal pr_url" \
  "$(jq -r '.[] | select(.run_id == "A") | .pr_url' <<<"$complete")" "https://x/pull/1"
assert_eq "complete runs: missing file yields empty array (rc 0)" \
  "$(drain_complete_runs "$FIXTURES/does-not-exist.jsonl")" "[]"
# Fail-closed: a PRESENT but malformed run-state file must make the enumerator FAIL
# (non-zero), never mask a parse error into an empty result — watch-demotion aborts on it.
tests_run=$((tests_run + 1))
if drain_complete_runs "$FIXTURES/drain-runs-malformed.jsonl" >/dev/null 2>&1; then
  faild "drain_complete_runs: FAILS CLOSED (non-zero) on malformed jsonl"
else
  pass "drain_complete_runs: FAILS CLOSED (non-zero) on malformed jsonl"
fi

# 12c. drain_demotion_already_recorded — idempotency key is (kind, merge_sha). The fixture
# holds one revert event for merge abc123.
tests_run=$((tests_run + 1))
if drain_demotion_already_recorded "revert" "abc123" "$FIXTURES/demotion-events-sample.jsonl"; then
  pass "demotion dedup: (revert, abc123) is already recorded"
else
  faild "demotion dedup: (revert, abc123) is already recorded"
fi
tests_run=$((tests_run + 1))
if drain_demotion_already_recorded "revert" "def456" "$FIXTURES/demotion-events-sample.jsonl"; then
  faild "demotion dedup: (revert, def456) is NOT recorded (different merge_sha)"
else
  pass "demotion dedup: (revert, def456) is NOT recorded (different merge_sha)"
fi
tests_run=$((tests_run + 1))
if drain_demotion_already_recorded "gate-regression" "abc123" "$FIXTURES/demotion-events-sample.jsonl"; then
  faild "demotion dedup: (gate-regression, abc123) is NOT recorded (different kind)"
else
  pass "demotion dedup: (gate-regression, abc123) is NOT recorded (different kind)"
fi
tests_run=$((tests_run + 1))
if drain_demotion_already_recorded "revert" "abc123" "$FIXTURES/no-events-file.jsonl"; then
  faild "demotion dedup: missing events file -> not recorded (rc 1)"
else
  pass "demotion dedup: missing events file -> not recorded (rc 1)"
fi
# Fail-closed: a PRESENT but corrupt/truncated events file must NOT read as "not recorded"
# (rc 1, which would append blindly and defeat dedup forever) — it must return the distinct
# fail-closed code (rc 3) so record_event aborts loud. Mirrors the drain-runs-malformed guard.
if drain_demotion_already_recorded "revert" "abc123" "$FIXTURES/demotion-events-malformed.jsonl"; then
  dedup_corrupt_rc=0
else
  dedup_corrupt_rc=$?
fi
assert_eq "demotion dedup: corrupt events file FAILS CLOSED (rc 3, not 1)" "$dedup_corrupt_rc" "3"

# 12d. Idempotent re-run walk-through (the watcher's append contract, off fixtures / no
# network). Append an event, then assert a second detection of the SAME (kind, merge_sha)
# sees it already recorded (would skip the duplicate row) while a DIFFERENT merge_sha does
# not — the exact guard record_event applies before appending.
dedup_tmp="$(mktemp -d)"
trap 'rm -rf "$revrepo" "$attest_tmp" "$dedup_tmp"' EXIT
events_f="$dedup_tmp/demotion-events.jsonl"
jq -cn '{detected_at:"2026-07-22T09:00:00Z", kind:"gate-regression", merge_sha:"feedface",
  pr_url:"https://x/pull/9", run_id:"R9", detail:"gate on pr-head is failure"}' >>"$events_f"
tests_run=$((tests_run + 1))
if drain_demotion_already_recorded "gate-regression" "feedface" "$events_f"; then
  pass "demotion re-run: freshly appended (gate-regression, feedface) is seen on re-detect"
else
  faild "demotion re-run: freshly appended (gate-regression, feedface) is seen on re-detect"
fi
tests_run=$((tests_run + 1))
if drain_demotion_already_recorded "gate-regression" "cafed00d" "$events_f"; then
  faild "demotion re-run: a new merge_sha is not yet recorded"
else
  pass "demotion re-run: a new merge_sha is not yet recorded"
fi

# --- summary ----------------------------------------------------------------
printf '\n1..%d\n' "$tests_run"
if [[ "$tests_failed" -gt 0 ]]; then
  printf '%d of %d test(s) FAILED\n' "$tests_failed" "$tests_run" >&2
  exit 1
fi
printf 'all %d test(s) passed\n' "$tests_run"
