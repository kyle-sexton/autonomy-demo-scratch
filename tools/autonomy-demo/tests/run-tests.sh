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

# --- summary ----------------------------------------------------------------
printf '\n1..%d\n' "$tests_run"
if [[ "$tests_failed" -gt 0 ]]; then
  printf '%d of %d test(s) FAILED\n' "$tests_failed" "$tests_run" >&2
  exit 1
fi
printf 'all %d test(s) passed\n' "$tests_run"
