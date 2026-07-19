#!/usr/bin/env bash
# Tests for migrate-type-labels.sh — the pure logic (label -> native-type mapping,
# per-issue verdict aggregation, and the fail-closed absence discipline). The
# gh-touching apply/verify paths mutate shared coordination state and are exercised
# only under the gated post-merge run (PR body), never unit-tested here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=migrate-type-labels.sh
source "$SCRIPT_DIR/migrate-type-labels.sh"
# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

FAILED=0

# --- mtl_map_label_to_type ------------------------------------------------

OUT="$(mtl_map_label_to_type "type:fix")"
assert_eq "type:fix -> Bug" "Bug" "$OUT"
OUT="$(mtl_map_label_to_type "type: bug")"
assert_eq "colon-space type: bug -> Bug" "Bug" "$OUT"
OUT="$(mtl_map_label_to_type "type:feat")"
assert_eq "type:feat -> Feature" "Feature" "$OUT"
OUT="$(mtl_map_label_to_type "type: feature")"
assert_eq "colon-space type: feature -> Feature" "Feature" "$OUT"
OUT="$(mtl_map_label_to_type "type:chore")"
assert_eq "type:chore -> Task" "Task" "$OUT"
OUT="$(mtl_map_label_to_type "type: refactor")"
assert_eq "colon-space type: refactor -> Task" "Task" "$OUT"
OUT="$(mtl_map_label_to_type "type:docs")"
assert_eq "type:docs -> Task" "Task" "$OUT"
OUT="$(mtl_map_label_to_type "type:perf")"
assert_eq "type:perf -> Task" "Task" "$OUT"

mtl_map_label_to_type "area:ci-cd" >/dev/null
assert_eq "non-type label returns 1" "1" "$?"
mtl_map_label_to_type "type:wat" >/dev/null
assert_eq "unmapped type: label returns 2" "2" "$?"

# --- mtl_targets_from_labels ----------------------------------------------

OUT="$(printf '%s\n' "area:ci-cd" "type:chore" "automated" | mtl_targets_from_labels)"
assert_eq "single type label -> TARGET" "TARGET Task" "$OUT"

OUT="$(printf '%s\n' "type:docs" "type:chore" | mtl_targets_from_labels)"
assert_eq "two labels, same target -> single TARGET" "TARGET Task" "$OUT"

OUT="$(printf '%s\n' "type:fix" "type:chore" | mtl_targets_from_labels)"
assert_eq "disagreeing type labels -> CONFLICT (sorted, deduped)" "CONFLICT Bug,Task" "$OUT"

OUT="$(printf '%s\n' "type:chore" "type:wat" | mtl_targets_from_labels)"
assert_eq "any unmapped type: label -> UNMAPPED (never guessed)" "UNMAPPED type:wat" "$OUT"

OUT="$(printf '%s\n' "area:ci-cd" "automated" | mtl_targets_from_labels)"
assert_eq "no type label -> NONE" "NONE" "$OUT"

# --- mtl_type_labels_from_labels ------------------------------------------

OUT="$(printf '%s\n' "area:ci-cd" "type:chore" "automated" "type: refactor" | mtl_type_labels_from_labels | paste -sd, -)"
assert_eq "extracts only type:* labels" "type:chore,type: refactor" "$OUT"

# --- mtl_absence_verdict (fail-closed crux) -------------------------------

# verify() feeds a newline-separated list of label NAMES and an anchored `^type:`
# pattern (never raw JSON — a label DESCRIPTION mentioning type: must not false-trip).
V="$(
  mtl_absence_verdict 1 '' '^type:'
  echo "rc=$?"
)"
assert_contains "provider fetch failure is ERROR, never clean" "$V" "ERROR"
assert_contains "provider fetch failure returns code 2" "$V" "rc=2"

V="$(
  mtl_absence_verdict 0 "$(printf '%s\n' "area:ci-cd" "type:chore")" '^type:'
  echo "rc=$?"
)"
assert_contains "label still present is PRESENT" "$V" "PRESENT"
assert_contains "label present returns code 1" "$V" "rc=1"

V="$(
  mtl_absence_verdict 0 "$(printf '%s\n' "area:ci-cd" "needs-info")" '^type:'
  echo "rc=$?"
)"
assert_contains "clean fetch with no type: label is ABSENT" "$V" "ABSENT"
assert_contains "label absent returns code 0" "$V" "rc=0"

# A label whose NAME is not type:* but whose text merely contains "type:" must not
# match the anchored pattern (the false-positive verify() now guards against).
V="$(
  mtl_absence_verdict 0 "$(printf '%s\n' "area:ci-cd" "mentions type: somewhere")" '^type:'
  echo "rc=$?"
)"
assert_contains "non-anchored type: mention is still ABSENT" "$V" "ABSENT"

[[ $FAILED -eq 0 ]] || exit 1
