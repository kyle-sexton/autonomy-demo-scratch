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

# 2. off-schedule manual: origin transcript present, but enqueue at :36 past the hour.
mk_transcript "$proj/c2.jsonl" "2026-07-21T10:36:27.000Z" "scheduled-20260721T104250Z-bbbbbbbb"
a2="$("$ATTEST" scheduled-20260721T104250Z-bbbbbbbb)"
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
# enqueue :17:00 spawning run B (start :20:40, off-schedule). Run B's start is >900s
# after the :05:25 enqueue, so ONLY its own :17:00 enqueue is in-window (a single
# candidate), isolating the per-record resolution under test.
runA="scheduled-20260721T100601Z-a1a1a1a1"
runB="scheduled-20260721T102040Z-b2b2b2b2"
{ enq_line "2026-07-21T10:05:25.000Z"; fil_line "$runA"
  enq_line "2026-07-21T10:17:00.000Z"; fil_line "$runB"; } >"$proj/multi.jsonl"
m1="$("$ATTEST" "$runA")"
assert_eq "attest: multi-enqueue run A resolves to its own enqueue (aligned)" "$(att_flag "$m1")" "true"
assert_eq "attest: multi-enqueue run A reason slot-aligned" "$(att_reason "$m1")" "slot-aligned"
assert_eq "attest: multi-enqueue run A enqueue_ts is :05:25 (not merely first)" \
  "$(att_ets "$m1")" "2026-07-21T10:05:25.000Z"
m2="$("$ATTEST" "$runB")"
assert_eq "attest: multi-enqueue run B resolves to its OWN later enqueue (not first)" \
  "$(att_ets "$m2")" "2026-07-21T10:17:00.000Z"
assert_eq "attest: multi-enqueue run B off-schedule" "$(att_reason "$m2")" "off-schedule"
assert_eq "attest: multi-enqueue run B offset 1020" "$(att_off "$m2")" "1020"

# 9c. Two in-window enqueues both matching a single run_id -> ambiguous (fail closed;
# never pick one arbitrarily).
runC="scheduled-20260721T100601Z-c3c3c3c3"
{ enq_line "2026-07-21T10:05:20.000Z"; enq_line "2026-07-21T10:05:25.000Z"; fil_line "$runC"; } \
  >"$proj/multi-ambiguous.jsonl"
m3="$("$ATTEST" "$runC")"
assert_eq "attest: two in-window enqueues for one run_id -> ambiguous" \
  "$(att_reason "$m3")" "ambiguous-origin"
assert_eq "attest: ambiguous multi-enqueue not attested" "$(att_flag "$m3")" "false"

# --- summary ----------------------------------------------------------------
printf '\n1..%d\n' "$tests_run"
if [[ "$tests_failed" -gt 0 ]]; then
  printf '%d of %d test(s) FAILED\n' "$tests_failed" "$tests_run" >&2
  exit 1
fi
printf 'all %d test(s) passed\n' "$tests_run"
