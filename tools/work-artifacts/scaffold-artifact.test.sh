#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/scaffold-artifact.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/scaffold-artifact.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# --- Case 1: --help exits 0 with non-empty stdout (skill-script-contract gate) ---

help_out="$(bash "$SCRIPT" --help)"
assert_exit "--help exit 0" 0 "$?"
assert_contains "--help prints usage" "$help_out" "scaffold-artifact.sh"

# --- Case 2: journal note with --slug writes a correctly-named, populated entry ---

REPO="$TEST_TMPDIR/repo"
make_repo "$REPO"
install_slice_history_dir_fixture "$REPO"
out2="$(cd "$REPO" && CLAUDE_CODE_SESSION_ID=test-session-123 bash "$SCRIPT" journal note tracer-probe --slug scratch-probe)"
assert_exit "journal scaffold exit 0" 0 "$?"
assert_contains "prints journal path" "$out2" ".work/scratch-probe/journal/"
fname="$(basename "$out2")"
if [[ "$fname" =~ ^[0-9]{8}T[0-9]{6}Z-note-tracer-probe\.md$ ]]; then
  pass "filename matches ISO-basic-note-topic pattern"
else
  fail "filename matches ISO-basic-note-topic pattern" '^[0-9]{8}T[0-9]{6}Z-note-tracer-probe\.md$' "$fname"
fi
entry="$(cat "$out2")"
assert_contains "frontmatter type" "$entry" "type: note"
assert_contains "frontmatter slug" "$entry" "slug: scratch-probe"
assert_contains "frontmatter topic" "$entry" "topic: tracer-probe"
assert_contains "frontmatter session_id" "$entry" "session_id: test-session-123"
if grep -qE '^date: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$out2"; then
  pass "date is ISO-extended (matches filename instant)"
else
  fail "date is ISO-extended" "date: NNNN-NN-NNTNN:NN:NNZ" "$(grep '^date:' "$out2")"
fi
assert_contains "title fill marker present" "$entry" "<fill:"

# --- Case 3: default slug derives from branch when --slug omitted ---

(cd "$REPO" && git checkout -q -b feat/derive-me)
out3="$(cd "$REPO" && bash "$SCRIPT" journal handoff phase-x)"
assert_exit "default-slug exit 0" 0 "$?"
assert_contains "uses branch-derived slug" "$out3" ".work/derive-me/journal/"

# --- Case 4: SESSION_ID defaults to "unknown" when env unset ---

out4="$(cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" journal note no-session --slug s4)"
entry4="$(cat "$out4")"
assert_contains "session_id unknown fallback" "$entry4" "session_id: unknown"

# --- Case 5: invalid journaltype → exit 2 ---

(cd "$REPO" && bash "$SCRIPT" journal bogus topic --slug s5 >/dev/null 2>&1)
assert_exit "invalid journaltype → exit 2" 2 "$?"

# --- Case 6: unsupported artifact type → exit 2 (explore/research/etc are supported) ---

(cd "$REPO" && bash "$SCRIPT" frobnicate --slug s6 >/dev/null 2>&1)
assert_exit "unsupported artifact type → exit 2" 2 "$?"

# --- Case 7: outside a git repo → exit 1 ---

OUTSIDE="$TEST_TMPDIR/not-a-repo"
mkdir -p "$OUTSIDE"
(cd "$OUTSIDE" && bash "$SCRIPT" journal note x --slug s7 >/dev/null 2>&1)
assert_exit "outside repo → exit 1" 1 "$?"

# --- Case 8: missing topic → exit 2 ---

(cd "$REPO" && bash "$SCRIPT" journal note >/dev/null 2>&1)
assert_exit "missing topic → exit 2" 2 "$?"

# --- Case 9: each fixed-name type writes its correct CAPS filename at slice root ---

declare -A EXPECT_FNAME=([explore]=EXPLORE.md [research]=RESEARCH.md [plan]=PLAN.md [deviations]=DEVIATIONS.md)
for t in explore research plan deviations; do
  fixed_out="$(cd "$REPO" && bash "$SCRIPT" "$t" --slug "fx-$t")"
  assert_exit "fixed-name $t exit 0" 0 "$?"
  expected_rel=".work/fx-$t/${EXPECT_FNAME[$t]}"
  assert_contains "$t writes ${EXPECT_FNAME[$t]}" "$fixed_out" "$expected_rel"
  assert_file_exists "$t file exists on disk" "$REPO/$expected_rel"
done

# --- Case 10: fixed-name no-clobber — 2nd run preserves the file + exit 0 + same path ---
# (content-preservation is a strictly stronger, cross-platform proof than mtime:
# it fails even if an overwrite lands within the same filesystem-time tick.)

first_out="$(cd "$REPO" && bash "$SCRIPT" plan --slug clobber-probe)"
printf '\nHAND-EDITED-SENTINEL\n' >>"$first_out"
second_out="$(cd "$REPO" && bash "$SCRIPT" plan --slug clobber-probe)"
assert_exit "no-clobber 2nd run exit 0" 0 "$?"
assert_eq "no-clobber prints the same path" "$first_out" "$second_out"
assert_contains "no-clobber preserves hand edit" "$(cat "$first_out")" "HAND-EDITED-SENTINEL"

# --- Case 11: plan scaffold matches templates/plan.md (Brief + Plan + [TODO] phase) ---

plan_out="$(cd "$REPO" && bash "$SCRIPT" plan --slug plan-shape)"
plan_body="$(cat "$plan_out")"
assert_contains "plan has Brief" "$plan_body" "## Brief"
assert_contains "plan has Plan" "$plan_body" "## Plan"
if grep -qE '^### Phase [0-9]+: .+ \[TODO\]$' "$plan_out"; then
  pass "plan phase matches phase-tag grammar"
else
  fail "plan phase matches phase-tag grammar" '### Phase N: <name> [TODO]' "$(grep '### Phase' "$plan_out")"
fi
if diff -q "$SCRIPT_DIR/templates/plan.md" "$plan_out" >/dev/null; then
  pass "plan output byte-for-byte matches templates/plan.md"
else
  fail "plan output matches template" "identical to templates/plan.md" "differs"
fi

# --- Case 12: a fixed-name type rejects extra positional args → exit 2 ---

(cd "$REPO" && bash "$SCRIPT" explore junk --slug s12 >/dev/null 2>&1)
assert_exit "fixed-name extra positional → exit 2" 2 "$?"

# --- Case 13: unsafe <topic> is sanitized to a kebab filename component (no path traversal) ---
# A topic with path separators / '..' / whitespace must not escape the journal
# dir or break the locked filename contract; it is normalized to [A-Za-z0-9-].

out13="$(cd "$REPO" && bash "$SCRIPT" journal note '../../etc/passwd' --slug unsafe-topic)"
assert_exit "unsafe topic exit 0" 0 "$?"
assert_contains "unsafe topic stays under journal/" "$out13" ".work/unsafe-topic/journal/"
fname13="$(basename "$out13")"
if [[ "$fname13" =~ ^[0-9]{8}T[0-9]{6}Z-note-[A-Za-z0-9-]+\.md$ ]]; then
  pass "unsafe topic sanitized to kebab filename component"
else
  fail "unsafe topic sanitized" '^<TS>-note-<kebab>.md$' "$fname13"
fi
assert_file_exists "sanitized journal entry exists at the printed path" "$out13"

# --- Case 14: a clean kebab <topic> is passed through unchanged (no over-mangling) ---

out14="$(cd "$REPO" && bash "$SCRIPT" journal note already-clean-topic --slug clean-topic)"
assert_exit "clean topic exit 0" 0 "$?"
assert_contains "clean topic preserved verbatim" "$out14" "-note-already-clean-topic.md"

# --- Case 15: a <topic> with no kebab-safe characters → exit 2 ---

(cd "$REPO" && bash "$SCRIPT" journal note '///' --slug allslash >/dev/null 2>&1)
assert_exit "no-kebab-safe-char topic → exit 2" 2 "$?"

# --- Case 16: --slug path-traversal is rejected → exit 2 (cannot escape .work/) ---
# A `--slug ../x` would resolve slice_dir to "$target_root/.work/../x" and escape
# the slice tree. Path separators and '..' are blocked at parse; glob metachars
# are NOT (those are sanitized downstream — see ensure-slice-manifest Case 10).

(cd "$REPO" && bash "$SCRIPT" journal note probe --slug '../escape' >/dev/null 2>&1)
assert_exit "--slug '../escape' → exit 2" 2 "$?"
(cd "$REPO" && bash "$SCRIPT" plan --slug 'a/b' >/dev/null 2>&1)
assert_exit "--slug 'a/b' separator → exit 2" 2 "$?"
(cd "$REPO" && bash "$SCRIPT" plan --slug '..' >/dev/null 2>&1)
assert_exit "--slug '..' → exit 2" 2 "$?"
assert_file_absent "traversal did not create a sibling of .work/" "$REPO/escape"

# --- Case 17: a clean kebab --slug is still accepted (no over-rejection) ---

out17="$(cd "$REPO" && bash "$SCRIPT" plan --slug valid-slug-123)"
assert_exit "clean --slug exit 0" 0 "$?"
assert_contains "clean --slug creates slice" "$out17" ".work/valid-slug-123/PLAN.md"

[[ $FAILED -eq 0 ]] || exit 1
