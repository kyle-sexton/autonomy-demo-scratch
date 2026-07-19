#!/usr/bin/env bash
# Regression tests for tools/skill-infrastructure/test-skill-portability.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/test-skill-portability.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Synthetic fixtures live OUTSIDE the live .claude/skills/ tree so a killed
# run can never leak __test_* dirs into it (CC's skill scanner would pick them
# up mid-run otherwise). The script-under-test resolves them via the
# SKILL_PORTABILITY_SKILLS_ROOT override; real-skill cases (Tests 1/2) leave
# it unset and use the default repo skills root. The TEST_TMPDIR trap is the
# only cleanup needed — no per-fixture bookkeeping.
FIXTURE_ROOT="$TEST_TMPDIR/skills"
mkdir -p "$FIXTURE_ROOT"

FAILED=0
CASE_NUM=0
# shellcheck source=../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

# Boilerplate BEHAVIOR.md shared verbatim by the v2 deny-list fixtures (Tests
# 6-8) — declares the single test-point whose default.md carries the content
# under test. The point name tracks the fixture dir basename.
write_behavior_md() {
  local dir="$1"
  cat >"$dir/BEHAVIOR.md" <<EOF
## Point: $(basename "$dir").test-point
Type: text
Default merge: set
File: behavior/test-point/default.md
Description: Test fixture point.
EOF
}

# Test 2: /onboard is a non-adopter (no BEHAVIOR.md) — silent exit 0.
# Exercises the default (unset SKILL_PORTABILITY_SKILLS_ROOT) real-skills-root
# path against a live skill; the synthetic non-adopter case below covers the
# override path.
out=$(bash "$SCRIPT" onboard 2>&1)
exit_code=$?
assert_exit "onboard non-adopter exits 0" 0 "$exit_code"
assert_silent "onboard non-adopter silent" "$out"

# Test 3: non-adopter (no BEHAVIOR.md) exits 0 with skip message.
# Synthetic fixture (no BEHAVIOR.md) rather than a real skill name — real
# skills adopt behavior-layering over time (architect did during the EPIC),
# so hardcoding one as the "non-adopter" example is a recurring staleness
# trap. Mirrors the v2 fixture pattern in Tests 6-8.
NONADOPTER_DIR="$FIXTURE_ROOT/__test_nonadopter_$$"
mkdir -p "$NONADOPTER_DIR"
cat >"$NONADOPTER_DIR/SKILL.md" <<EOF
---
name: $(basename "$NONADOPTER_DIR")
description: "Test fixture: skill with no BEHAVIOR.md (non-adopter)."
---
No behavior layer here.
EOF
out=$(SKILL_PORTABILITY_SKILLS_ROOT="$FIXTURE_ROOT" bash "$SCRIPT" "$(basename "$NONADOPTER_DIR")" 2>&1)
exit_code=$?
assert_exit "non-adopter exits 0" 0 "$exit_code"
assert_silent "non-adopter silent" "$out"

# Test 4: missing skill name shows error
err_out=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "missing skill name shows usage" "$err_out" "Usage:"

# Test 5: nonexistent skill exits non-zero
out=$(bash "$SCRIPT" nonexistent-skill-xyz 2>&1 || true)
assert_contains "missing skill dir reports error" "$out" "FAIL: Skill not found"

# Test 6: v2 deny-list — HARD-FAIL token in default.yaml triggers exit 1
SKILL_FIXTURE_DIR="$FIXTURE_ROOT/__test_denylist_hardfail_$$"
mkdir -p "$SKILL_FIXTURE_DIR/behavior/test-point"
cat >"$SKILL_FIXTURE_DIR/SKILL.md" <<'EOF'
---
name: __test_denylist_hardfail
description: "Test fixture for v2 deny-list HARD-FAIL detection."
---
Test point: <!-- @behavior: __test_denylist_hardfail_PLACEHOLDER.test-point -->
EOF
# Substitute the dynamic skill name + actual @behavior marker
sed -i "s/__test_denylist_hardfail_PLACEHOLDER/$(basename "$SKILL_FIXTURE_DIR")/" "$SKILL_FIXTURE_DIR/SKILL.md"
write_behavior_md "$SKILL_FIXTURE_DIR"
# default.md embeds a HARD-FAIL token (Medley.slnx)
cat >"$SKILL_FIXTURE_DIR/behavior/test-point/default.md" <<EOF
---
'@behavior': $(basename "$SKILL_FIXTURE_DIR").test-point
merge: set
---
Build with Medley.slnx solution file.
EOF
out=$(SKILL_PORTABILITY_SKILLS_ROOT="$FIXTURE_ROOT" bash "$SCRIPT" "$(basename "$SKILL_FIXTURE_DIR")" 2>&1 || true)
assert_contains "v2 HARD-FAIL token triggers FAIL" "$out" "Repo-specific identifier 'Medley.slnx'"
assert_contains "v2 HARD-FAIL exits non-zero" "$out" "PORTABILITY: FAIL"

# Test 7: v2 deny-list — WARN token in default.yaml passes with warning
SKILL_FIXTURE_DIR="$FIXTURE_ROOT/__test_denylist_warn_$$"
mkdir -p "$SKILL_FIXTURE_DIR/behavior/test-point"
cat >"$SKILL_FIXTURE_DIR/SKILL.md" <<EOF
---
name: $(basename "$SKILL_FIXTURE_DIR")
description: "Test fixture for v2 deny-list WARN detection."
---
Test point: <!-- @behavior: $(basename "$SKILL_FIXTURE_DIR").test-point -->
EOF
write_behavior_md "$SKILL_FIXTURE_DIR"
cat >"$SKILL_FIXTURE_DIR/behavior/test-point/default.md" <<EOF
---
'@behavior': $(basename "$SKILL_FIXTURE_DIR").test-point
merge: set
---
Use Aspire AppHost for orchestration.
EOF
out=$(SKILL_PORTABILITY_SKILLS_ROOT="$FIXTURE_ROOT" bash "$SCRIPT" "$(basename "$SKILL_FIXTURE_DIR")" 2>&1)
exit_code=$?
assert_exit "v2 WARN token exits 0" 0 "$exit_code"
assert_contains "v2 WARN token emits WARN line" "$out" "Stack-choice token 'Aspire' (WARN)"
assert_contains "v2 WARN passes overall" "$out" "PORTABILITY: PASS"

# Test 8: v2 deny-list — per-line opt-out marker suppresses scan
SKILL_FIXTURE_DIR="$FIXTURE_ROOT/__test_denylist_optout_$$"
mkdir -p "$SKILL_FIXTURE_DIR/behavior/test-point"
cat >"$SKILL_FIXTURE_DIR/SKILL.md" <<EOF
---
name: $(basename "$SKILL_FIXTURE_DIR")
description: "Test fixture for v2 deny-list opt-out marker."
---
Test point: <!-- @behavior: $(basename "$SKILL_FIXTURE_DIR").test-point -->
Team layer carries Medley.slnx config. <!-- portability-scan-ignore-line -->
EOF
write_behavior_md "$SKILL_FIXTURE_DIR"
cat >"$SKILL_FIXTURE_DIR/behavior/test-point/default.md" <<EOF
---
'@behavior': $(basename "$SKILL_FIXTURE_DIR").test-point
merge: set
---
Default content with no repo-specifics.
EOF
out=$(SKILL_PORTABILITY_SKILLS_ROOT="$FIXTURE_ROOT" bash "$SCRIPT" "$(basename "$SKILL_FIXTURE_DIR")" 2>&1)
exit_code=$?
assert_exit "v2 opt-out marker exits 0" 0 "$exit_code"
assert_not_contains "v2 opt-out marker suppresses HARD-FAIL" "$out" "Repo-specific identifier 'Medley.slnx'"

[[ "$FAILED" -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
