#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/lib/fill-template.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/fill-template.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0
# shellcheck source=../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# shellcheck source=fill-template.sh
source "$LIB"

# --- Case 1: substitutes named placeholders ---

tpl1="$TEST_TMPDIR/t1.md"
printf '%s\n' "slug: \${SLUG}" "type: \${TYPE}" >"$tpl1"
export SLUG="my-slug" TYPE="note"
out1="$(fill_template "$tpl1")"
assert_contains "SLUG substituted" "$out1" "slug: my-slug"
assert_contains "TYPE substituted" "$out1" "type: note"

# --- Case 2: subset template does not trip set -u on unset placeholders ---
# SLUG_TITLE/DATE/TIMESTAMP/TOPIC/SESSION_ID unset here — each must substitute to
# empty (nameref + ${ref:-}), not error.

unset SLUG_TITLE DATE TIMESTAMP TOPIC SESSION_ID 2>/dev/null || true
tpl2="$TEST_TMPDIR/t2.md"
printf '%s\n' "only: \${SLUG}" >"$tpl2"
export SLUG="x"
rc=0
out2="$(fill_template "$tpl2")" || rc=$?
assert_exit "subset template exits 0" 0 "$rc"
assert_contains "subset substitutes SLUG" "$out2" "only: x"

# --- Case 3: <fill: …> markers left untouched ---

tpl3="$TEST_TMPDIR/t3.md"
printf '%s\n' "a: \${SLUG}" "keep: <fill: model resolves this>" >"$tpl3"
export SLUG="z"
out3="$(fill_template "$tpl3")"
assert_contains "fill marker preserved" "$out3" "<fill: model resolves this>"

# --- Case 4: exactly one trailing newline (byte-for-byte parity) ---
# Template carries three trailing newlines; output must carry exactly one.

tpl4="$TEST_TMPDIR/t4.md"
printf '%s\n\n\n' "line: \${SLUG}" >"$tpl4"
export SLUG="q"
out4="$(
  fill_template "$tpl4"
  printf 'END'
)"
assert_eq "single trailing newline before END" "line: q"$'\n'"END" "$out4"

[[ $FAILED -eq 0 ]] || exit 1
