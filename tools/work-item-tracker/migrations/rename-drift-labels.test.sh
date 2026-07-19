#!/usr/bin/env bash
# Tests for rename-drift-labels.sh — the pure logic (the closed rename map lookup and
# the fail-closed absence discipline). The gh-touching dry-run/apply/verify paths hit
# live label state and are exercised only under the gated post-merge run (PR body),
# never unit-tested here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=rename-drift-labels.sh
source "$SCRIPT_DIR/rename-drift-labels.sh"
# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

FAILED=0

# --- rdl_target_for_label (the closed rename map) -------------------------

OUT="$(rdl_target_for_label "category:guardrails")"
assert_eq "category:guardrails -> area: guardrails (prefix + colon-space)" "area: guardrails" "$OUT"
OUT="$(rdl_target_for_label "area:claude-code")"
assert_eq "area:claude-code -> area: claude-code (colon-space)" "area: claude-code" "$OUT"
OUT="$(rdl_target_for_label "area:ci-cd")"
assert_eq "area:ci-cd -> area: ci-cd (colon-space)" "area: ci-cd" "$OUT"
OUT="$(rdl_target_for_label "wayfind:research")"
assert_eq "wayfind:research -> wayfind: research" "wayfind: research" "$OUT"
OUT="$(rdl_target_for_label "wayfind:task")"
assert_eq "wayfind:task -> wayfind: task" "wayfind: task" "$OUT"

rdl_target_for_label "area: security" >/dev/null
assert_eq "already-canonical label is not a rename source (rc 1)" "1" "$?"
rdl_target_for_label "category:general" >/dev/null
assert_eq "undeclared category:general is NOT auto-renamed (rc 1)" "1" "$?"
rdl_target_for_label "javascript" >/dev/null
assert_eq "javascript is NOT a rename source (rc 1)" "1" "$?"
rdl_target_for_label "type:chore" >/dev/null
assert_eq "out-of-axis label is not a rename source (rc 1)" "1" "$?"

# --- rdl_absence_verdict (fail-closed crux) -------------------------------

# verify() feeds a newline-separated list of label NAMES and an anchored pattern; a
# provider fetch failure must surface as ERROR, never a clean/empty ABSENT.
V="$(
  rdl_absence_verdict 1 '' '^category:guardrails$'
  echo "rc=$?"
)"
assert_contains "provider fetch failure is ERROR, never clean" "$V" "ERROR"
assert_contains "provider fetch failure returns code 2" "$V" "rc=2"

V="$(
  rdl_absence_verdict 0 "$(printf '%s\n' "area: security" "category:guardrails")" '^category:guardrails$'
  echo "rc=$?"
)"
assert_contains "drifted label still present is PRESENT" "$V" "PRESENT"
assert_contains "label present returns code 1" "$V" "rc=1"

V="$(
  rdl_absence_verdict 0 "$(printf '%s\n' "area: security" "area: guardrails")" '^category:guardrails$'
  echo "rc=$?"
)"
assert_contains "drifted label gone is ABSENT" "$V" "ABSENT"
assert_contains "label absent returns code 0" "$V" "rc=0"

[[ $FAILED -eq 0 ]] || exit 1
