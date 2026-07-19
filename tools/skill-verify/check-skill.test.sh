#!/usr/bin/env bash
# Regression tests for tools/skill-verify/check-skill.sh.
#
# Fixture skills live OUTSIDE the live .claude/skills/ tree (TEST_TMPDIR) so a
# killed run can never leak __test_* dirs the CC scanner would pick up. The
# script-under-test resolves them via the CHECK_SKILL_SKILLS_ROOT override.
#
# Checks 3 (keyword-preservation), 8 (vendor/), 9 (metadata) read the REAL
# repo's `git show HEAD:.claude/skills/<name>/SKILL.md`, so for fixture names
# absent from HEAD they gracefully skip ("new skill"). Those three are
# validated by the live baseline run on real pilots, not by these fixtures.
# CHECK_SKILL_SKIP_MARKDOWNLINT=1 keeps fixture cases off default-config
# markdownlint (real skills violate MD041/MD013 by design; repo config exempts).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-skill.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FIXTURE_ROOT="$TEST_TMPDIR/skills"
mkdir -p "$FIXTURE_ROOT"

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

# Run the gate against a fixture skill (markdownlint suppressed).
run_check() {
  CHECK_SKILL_SKIP_MARKDOWNLINT=1 CHECK_SKILL_SKILLS_ROOT="$FIXTURE_ROOT" \
    bash "$SCRIPT" "$1" 2>&1
}

# Scaffold a fixture skill dir; $2 is the full SKILL.md body.
make_skill() {
  local name="$1" body="$2"
  mkdir -p "$FIXTURE_ROOT/$name"
  printf '%s\n' "$body" >"$FIXTURE_ROOT/$name/SKILL.md"
}

# --- Test 1: valid fixture passes ------------------------------------------
make_skill "__test_pass_$$" "$(
  cat <<'EOF'
---
name: __test_pass
description: "A valid fixture skill. Use when: 'thing happens', 'other thing'."
---

## Body

Short body line.
EOF
)"
out="$(run_check "__test_pass_$$")"
code=$?
assert_exit "valid fixture exits 0" 0 "$code"
assert_contains "valid fixture reports PASS" "$out" "PASS"

# --- Test 2: missing frontmatter fails -------------------------------------
make_skill "__test_nofm_$$" "$(
  cat <<'EOF'
## No frontmatter here

Body only.
EOF
)"
out="$(run_check "__test_nofm_$$" || true)"
assert_contains "missing frontmatter fails" "$out" "no YAML frontmatter"

# --- Test 3: missing name fails --------------------------------------------
make_skill "__test_noname_$$" "$(
  cat <<'EOF'
---
description: "Has a description but no name field."
---

## Body
EOF
)"
out="$(run_check "__test_noname_$$" || true)"
assert_contains "missing name fails" "$out" "missing 'name:'"

# --- Test 4: oversize description fails (>1536 chars) ----------------------
LONG_DESC="$(printf 'x%.0s' {1..1600})"
make_skill "__test_longdesc_$$" "$(
  cat <<EOF
---
name: __test_longdesc
description: "$LONG_DESC"
---

## Body
EOF
)"
out="$(run_check "__test_longdesc_$$" || true)"
assert_contains "oversize description fails" "$out" "cap $((1536))"

# --- Test 5: >= 500 lines fails --------------------------------------------
{
  printf -- '---\nname: __test_big\ndescription: "Big skill."\n---\n\n## Body\n'
  for _ in {1..600}; do printf 'filler line\n'; done
} >"$TEST_TMPDIR/big-body.md"
mkdir -p "$FIXTURE_ROOT/__test_big_$$"
cp "$TEST_TMPDIR/big-body.md" "$FIXTURE_ROOT/__test_big_$$/SKILL.md"
out="$(run_check "__test_big_$$" || true)"
assert_contains "oversize file fails" "$out" "hard cap 500"

# --- Test 6: broken skill-internal ref fails -------------------------------
make_skill "__test_brokenref_$$" "$(
  cat <<'EOF'
---
name: __test_brokenref
description: "References a missing context file."
---

## Body

See `context/missing.md` for detail.
EOF
)"
out="$(run_check "__test_brokenref_$$" || true)"
assert_contains "broken internal ref fails" "$out" "broken skill-internal ref"

# --- Test 7: resolvable skill-internal ref passes --------------------------
make_skill "__test_goodref_$$" "$(
  cat <<'EOF'
---
name: __test_goodref
description: "References an existing context file."
---

## Body

See `context/present.md` for detail.
EOF
)"
mkdir -p "$FIXTURE_ROOT/__test_goodref_$$/context"
printf 'present\n' >"$FIXTURE_ROOT/__test_goodref_$$/context/present.md"
out="$(run_check "__test_goodref_$$")"
code=$?
assert_exit "resolvable ref exits 0" 0 "$code"
assert_not_contains "resolvable ref not flagged" "$out" "broken skill-internal ref"

# --- Test 7b: broken markdown-LINK-form ref fails (not just backtick) ------
make_skill "__test_linkref_$$" "$(
  cat <<'EOF'
---
name: __test_linkref
description: "References a missing context file via markdown link."
---

## Body

See [the loop](context/missing-loop.md) for detail.
EOF
)"
out="$(run_check "__test_linkref_$$" || true)"
assert_contains "broken link-form ref fails" "$out" "broken skill-internal ref"

# --- Test 7c: placeholder-segment ref is not flagged (check-5 FP class d) ---
# A `context/<topic>.md` path is an illustrative placeholder, not a real file.
# The check-5 grep char-class excludes `<` `>`, so such refs never enter the
# resolution loop — lock that so a future char-class change can't silently
# start flagging documentation examples as broken refs.
make_skill "__test_placeholder_$$" "$(
  cat <<'EOF'
---
name: __test_placeholder
description: "Shows a placeholder path form."
---

## Body

Write the topic file at `context/<topic>.md` (placeholder, not a real file).
EOF
)"
out="$(run_check "__test_placeholder_$$")"
code=$?
assert_exit "placeholder-segment ref exits 0" 0 "$code"
assert_not_contains "placeholder-segment ref not flagged" "$out" "broken skill-internal ref"

# --- Test 8: missing skill dir fails ---------------------------------------
out="$(run_check "__test_absent_xyz_$$" || true)"
assert_contains "missing skill dir reports error" "$out" "Skill not found"

# --- Test 9: --help prints usage -------------------------------------------
out="$(bash "$SCRIPT" --help 2>&1)"
code=$?
assert_exit "--help exits 0" 0 "$code"
assert_contains "--help prints usage" "$out" "Usage:"

[[ "$FAILED" -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
