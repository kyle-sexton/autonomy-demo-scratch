#!/usr/bin/env bash
# Regression tests for tools/skill-contract/skill-encapsulation-check.sh.
#
# Focus: simplified public-surface contract — any subdir under
# `.claude/skills/<X>/` is private; `*.schema.json` at any depth is private;
# `<X>/SKILL.md#anchor` heading-anchor cites are private. Bare
# `<X>/SKILL.md` (no anchor), `<X>/<file>.json` data files (no .schema
# infix, Q2 carve-out), AND `<X>/scripts/<file>` entry scripts (T7b
# entry-surface carve-out) remain legal external surfaces.
#
# scripts/ carve-out (T7b): a skill's scripts/ is its declared ENTRY surface
# per skill/encapsulation.md "Public surface contract". This inbound gate no
# longer flags `<X>/scripts/...` cites from ANY external citer (harness / CI /
# hooks / lefthook lanes / workflow registries — and even sibling SKILL.md).
# The sibling-skill→scripts/ half of the asymmetry (skill→skill stays
# slash-only) is owned by outbound-direction-check.sh V2 (the documented
# inbound/outbound asymmetry, I3), not here.
#
# Coverage:
#   - arbitrary subdir names (data/, cache/, agents/, wrappers/, output/) fire
#   - heading-anchor `SKILL.md#<anchor>` fires
#   - schema files at skill root fire (incl. from CI/hook citers)
#   - data files at skill root (catalog.json) do NOT fire (Q2 carve-out)
#   - bare SKILL.md path cites do NOT fire (Phase 1 keeps legal)
#   - `<X>/scripts/<file>` entry-script cites do NOT fire (T7b carve-out) —
#     from external file, relative-form, AND sibling SKILL.md (V2 owns that)
#   - relative-form `../skills/<X>/<subdir>/` cites fire (non-scripts)
#   - routine-mirror exemption is GONE (formerly KIND-4) — routine cites
#     into matching skill internals now fire as violations
#   - KIND-2 forced-cite case branches still exempt their files (workflow
#     paths-trigger files, drift-gate scripts, etc.)
#   - blanket CI/hook narrow exception is GONE — fictional non-listed
#     workflow citing skill SCHEMA (not scripts/) DOES fire as violation
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/skill-encapsulation-check.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

# Build the shared base fixture ONCE: a git repo with the skeleton scan-scope
# dirs the hook walks + the seed placeholder SKILL.md every case needs. Per case,
# setup_repo derives a fresh repo by `cp -r` (measured ~3x faster than re-running
# `git init` on Git Bash: ~113ms vs ~346ms) and adds only that case's consumer
# file — amortizing the per-case fixture build (C2). A `cp -r` of a freshly-init'd
# repo is a valid independent repo; the placeholder stays untracked, matching the
# original (which never committed it). The base is never mutated after build, so
# each case stays fully isolated.
BASE_REPO="$TEST_TMPDIR/base-repo"
git init --quiet "$BASE_REPO"
(
  cd "$BASE_REPO" || exit 1
  mkdir -p .claude/routines .claude/rules .claude/skills/placeholder \
    .github/workflows .lefthook/pre-commit docs

  # The hook's cross-skill scan pipes `find .claude/skills -name SKILL.md` into
  # `xargs grep` for PRIVATE_RE. If no SKILL.md matches, grep exits 1 → xargs
  # propagates 123 under pipefail. Seed a self-cite (grep finds it; the
  # self-cite filter dismisses it) so the cross-skill pipeline stays exit 0.
  printf '# placeholder\n.claude/skills/placeholder/context/x.md\n' \
    >.claude/skills/placeholder/SKILL.md
)

# Stand up a per-case repo by copying the base fixture and adding the staged
# consumer file that carries the citation under test (the hook early-exits with
# nothing staged in scan-scope). No `git config user.*`: the test only `git add`s
# (never commits), so a committer identity is never consulted.
setup_repo() {
  local consumer_relpath="$1" citation="$2"
  local repo="$TEST_TMPDIR/repo-$CASE_NUM"
  rm -rf "$repo"
  cp -r "$BASE_REPO" "$repo"
  (
    cd "$repo" || exit 1
    # Consumer file carrying the citation under test. The citation is the only
    # body content — anything else risks false-positive PRIVATE_RE matches.
    consumer_dir="${consumer_relpath%/*}"
    [[ "$consumer_dir" == "$consumer_relpath" ]] && consumer_dir="."
    mkdir -p "$consumer_dir"
    printf '%s\n' "$citation" >"$consumer_relpath"
    git add "$consumer_relpath"
  )
  echo "$repo"
}

run_hook_in_repo() {
  (cd "$1" && bash "$HOOK" 2>&1)
}

# Helper: assert clean (exit 0, no violation message).
assert_legal() {
  local label="$1" consumer="$2" citation="$3"
  local repo out rc
  repo=$(setup_repo "$consumer" "$citation")
  out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
  assert_exit "$label (exit)" 0 "$rc"
  assert_not_contains "$label (no violation msg)" "$out" "violation(s) found"
}

# Helper: assert violation (exit 1, message names the consumer + citation).
assert_violation() {
  local label="$1" consumer="$2" citation="$3"
  local repo out rc
  repo=$(setup_repo "$consumer" "$citation")
  out=$(run_hook_in_repo "$repo") && rc=0 || rc=$?
  assert_exit "$label (exit)" 1 "$rc"
  assert_contains "$label (violation msg)" "$out" "violation(s) found"
  assert_contains "$label (cites consumer)" "$out" "$consumer"
}

# Case: hook script parses
if ! bash -n "$HOOK"; then
  fail "hook parses" "exit 0" "syntax error"
else
  pass "hook parses with bash -n"
fi

# --- Generalized PRIVATE_RE: arbitrary subdir names fire ---
# Enumerated kinds (context, reference, references, actions, evals, lanes,
# templates, scripts) still fire as before.
assert_violation "context/ fires (enumerated kind retained)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/context/foo.md"

assert_violation "reference/ fires" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/reference/exclusions.md"

assert_violation "references/ fires (plural variant)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/references/foo.md"

assert_violation "actions/ fires" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/actions/do-something.md"

assert_violation "templates/ fires" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/templates/output.md"

assert_violation "evals/ fires" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/evals/evals.json"

assert_violation "lanes/ fires" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/lanes/foo.md"

# --- Generalized PRIVATE_RE: NEWLY-COVERED arbitrary subdir names fire ---
assert_violation "data/ fires (generalized, not in historical enumeration)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/data/cache.json"

assert_violation "cache/ fires (generalized)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/cache/transcripts.json"

assert_violation "agents/ fires (generalized)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/agents/X.md"

assert_violation "wrappers/ fires (generalized)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/wrappers/foo.md"

assert_violation "output/ fires (generalized)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/output/result.md"

# --- Generalized PRIVATE_RE: schema files at skill root fire ---
assert_violation "*.schema.json at skill root fires" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/catalog.schema.json for validation"

# --- Heading-anchor RE: SKILL.md#<anchor> fires ---
assert_violation "SKILL.md#anchor fires (heading-anchor cite is private)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/SKILL.md#action-foo"

# --- NEGATIVE: Q2 data-file carve-out — root-level <X>/<file>.json does NOT fire ---
assert_legal "data file at skill root does NOT fire (Q2 carve-out)" \
  ".claude/routines/tidy.md" "see .claude/skills/onboard/catalog.json for the data"

# --- NEGATIVE: bare SKILL.md path cite (no anchor) is legal (Phase 1) ---
assert_legal "bare <X>/SKILL.md path cite does NOT fire (Phase 1 keeps legal)" \
  ".claude/routines/tidy.md" "see .claude/skills/onboard/SKILL.md for full reference"

# --- NEGATIVE: scripts/ entry-surface carve-out (T7b) — does NOT fire ---
# A skill's scripts/ is its declared entry surface (skill/encapsulation.md
# "Public surface contract"). External cites to scripts/ entry scripts are
# legal here regardless of citer; the sibling-skill→scripts/ half of the
# asymmetry is owned by outbound-direction-check.sh V2, not this inbound gate.
assert_legal "external file citing <X>/scripts/<f>.sh does NOT fire (T7b carve-out)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/scripts/foo.sh"

assert_legal "relative-form ../skills/<X>/scripts/ cite does NOT fire (T7b)" \
  ".claude/routines/tidy.md" "see ../skills/tidy/scripts/foo.sh"

# sibling SKILL.md citing another skill's scripts/ — legal HERE; the skill→skill
# slash-only rule is enforced by outbound-direction-check.sh V2 (asymmetry I3),
# so this inbound gate must NOT double-flag it.
assert_legal "sibling SKILL.md citing another skill's scripts/ does NOT fire here (V2 owns it)" \
  ".claude/skills/tidy/SKILL.md" "see .claude/skills/onboard/scripts/check-update.sh"

# --- Routine-mirror exemption REMOVED ---
# Previously, .claude/routines/<X>.md citing .claude/skills/<X>/<context|reference|references|actions|templates>/...
# was exempt as KIND-4 routine-skill mirror. Phase 1.1 removed the exemption
# from the contract; Phase 1.3 removes the case branch from the detector.
# Routine name matching skill name no longer matters — all external cites fire.
assert_violation "routine-mirror context/ NO LONGER exempt (KIND-4 removed)" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/context/foo.md"

assert_violation "routine-mirror reference/ NO LONGER exempt" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/reference/exclusions.md"

assert_violation "routine-mirror actions/ NO LONGER exempt" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/actions/do-something.md"

# --- CI/hook scripts/ cites are LEGAL (T7b entry-surface carve-out) ---
# Pre-T7b, .github/* / .lefthook/* citing scripts/ fired unless allow-listed
# as KIND-2. Post-T7b, scripts/ is the skill's declared ENTRY surface —
# harness / CI / hooks / lefthook lanes / workflow registries MAY path-cite it
# directly (skill/encapsulation.md "CI / git-hook consumption — entry surface,
# not internals"). So an arbitrary (non-allow-listed) workflow / hook citing
# scripts/ is now legal WITHOUT a KIND-2 case branch.
assert_legal "arbitrary workflow citing skill scripts/ is legal (T7b entry surface)" \
  ".github/workflows/test-fictional.yml" "      - '.claude/skills/onboard/scripts/check-update.sh'"

assert_legal "arbitrary hook citing skill scripts/ is legal (T7b entry surface)" \
  ".lefthook/pre-commit/test-fictional.sh" "echo .claude/skills/onboard/scripts/foo.sh"

# Schema files stay PRIVATE — the carve-out is scripts/ ONLY. A workflow citing
# a skill schema still fires (route via tools/schemas/ or /skill-name action).
assert_violation "fictional workflow citing skill schema fires (schema still private)" \
  ".github/workflows/test-fictional.yml" "      - '.claude/skills/onboard/catalog.schema.json'"

# --- KIND-2 case-branch entries (forced cite) preserved ---
# onboard-drift.yml paths: triggers structurally require skill-canonical paths
# so workflow fires when writer-side files change.
assert_legal "onboard-drift.yml paths: trigger is KIND-2 (forced cite)" \
  ".github/workflows/onboard-drift.yml" "      - '.claude/skills/onboard/scripts/check-update.sh'"

assert_legal "onboard-drift.yml schema path is KIND-2" \
  ".github/workflows/onboard-drift.yml" "      - '.claude/skills/onboard/catalog.schema.json'"

# shell-lint.yml Pester job consumes machine-health full skill (Technique 1).
assert_legal "shell-lint.yml machine-health Pester path is KIND-2" \
  ".github/workflows/shell-lint.yml" "      - '.claude/skills/machine-health/tests/PesterConfiguration.psd1'"

# ci-status.yml ecosystem-regex enumerates machine-health path (Technique 1).
assert_legal "ci-status.yml ecosystem regex Pester path is KIND-2" \
  ".github/workflows/ci-status.yml" "check_ecosystem shell .claude/skills/machine-health/tests/PesterConfiguration.psd1"

# onboard-schema-drift.sh body STRUCTURALLY cites both canonical and vendored
# paths — its sole job is comparing the pair.
assert_legal "onboard-schema-drift.sh body cites are KIND-2" \
  ".lefthook/pre-commit/onboard-schema-drift.sh" '".claude/skills/onboard/catalog.schema.json|tools/schemas/onboard-catalog.schema.json"'

# lefthook.yml onboard-catalog-schema lane glob must cite the skill-canonical
# catalog data path so the lane fires when that file changes — mechanical
# glob trigger, same forced-cite class as onboard-drift.yml paths: trigger.
assert_legal "lefthook.yml mechanical glob is KIND-2" \
  "lefthook.yml" '      glob: ".claude/skills/onboard/catalog.json"'

# --- KIND-1 meta-prose case-branch entries preserved ---
# Files that describe skill internals as documentation, worked examples, or
# empirically-verified quirks rather than reach-in dependencies.
assert_legal "powershell/conventions.md describing Pester paths is KIND-1" \
  ".claude/rules/powershell/conventions.md" "Pester tests at .claude/skills/machine-health/tests/Invoke-MachineHealthTests.ps1"

assert_legal "skill/quirks.md empirical-test path is KIND-1" \
  ".claude/rules/skill/quirks.md" "placed a valid SKILL.md at .claude/skills/custom/test-nested-skill/SKILL.md"

assert_legal "docs/ecosystems/powershell-reference.md describing Pester is KIND-1" \
  "docs/ecosystems/powershell-reference.md" "see .claude/skills/machine-health/tests/Invoke-MachineHealthTests.ps1"

assert_legal "REVIEW.md exclusion glob is KIND-1" \
  "REVIEW.md" "':!:.claude/skills/course-digest/data/**'"

# --- Self-citation: skill citing its own private surface is legal ---
# Synthetic check via the cross-skill SKILL.md scan loop. The seed SKILL.md
# in setup_repo already cites .claude/skills/placeholder/context/x.md → the
# self-cite filter handles this. Verified by every "legal" case above
# returning clean exit 0.

# --- Relative-form RE: ../skills/<X>/<subdir>/ cites fire ---
assert_violation "relative-form subdir cite fires" \
  ".claude/routines/tidy.md" "see ../skills/tidy/context/foo.md"

assert_violation "relative-form schema cite fires" \
  ".claude/routines/tidy.md" "see ../skills/tidy/catalog.schema.json"

assert_violation "relative-form heading-anchor cite fires" \
  ".claude/routines/tidy.md" "see ../skills/tidy/SKILL.md#action-foo"

# --- .claude/workflows/*.js scope: engine citing skill internals fires ---
# Workflow engine scripts (.js) are in scan scope; the grep --include list
# carries *.js so a path cite into a skill-private subdir is caught. Without
# the *.js include OR the .claude/workflows/ dir in scope, this would bypass.
assert_violation "workflow .js citing skill private subdir fires" \
  ".claude/workflows/research-deep-fanout.js" \
  "    '  .claude/skills/research/behavior/ecosystem-source-table/default.yaml',"

assert_violation "workflow .js citing skill schema fires" \
  ".claude/workflows/some-engine.js" \
  "  see .claude/skills/onboard/catalog.schema.json"

assert_violation "workflow .js citing skill heading-anchor fires" \
  ".claude/workflows/some-engine.js" \
  "  see .claude/skills/research/SKILL.md#mandatory-disciplines"

# --- .claude/workflows/*.js: bare SKILL.md path cite stays legal ---
# The repointed research-deep-fanout engine cites research/SKILL.md (no subdir,
# no anchor) for the canonical /research discipline — that is the public surface.
assert_legal "workflow .js bare SKILL.md cite does NOT fire" \
  ".claude/workflows/research-deep-fanout.js" \
  "  Read .claude/skills/research/SKILL.md for the canonical workflow"

# --- Per-cite masking fix (gates/DEVIATIONS Phase 2) ---
# Both line-level filters (self-citation, scripts/ entry-surface carve-out)
# historically dropped at WHOLE-LINE granularity: a single line citing an
# exempt surface (a skill's own path, or a <X>/scripts/ entry script) AND a
# genuine other-skill private subdir was silently dropped, masking the real
# violation. The per-cite refactor (the scan grep's -o flag emits one record
# per cite, each filtered individually) flags the line iff a non-exempt cite
# survives both exemptions.
assert_violation "mixed line: scripts/ entry cite + other-skill private cite still fires" \
  ".claude/routines/tidy.md" \
  "see .claude/skills/tidy/scripts/foo.sh and .claude/skills/onboard/context/bar.md"

assert_violation "mixed line: order-independent — private cite BEFORE scripts/ cite still fires" \
  ".claude/routines/tidy.md" \
  "see .claude/skills/onboard/reference/bar.md and .claude/skills/tidy/scripts/foo.sh"

assert_violation "mixed line: self-cite + other-skill private cite still fires" \
  ".claude/skills/tidy/SKILL.md" \
  "see .claude/skills/tidy/context/self.md and .claude/skills/onboard/context/other.md"

# Pure exempt lines remain legal under the per-cite filter (pin exemptions).
assert_legal "pure scripts/ entry cite still legal under per-cite filter" \
  ".claude/routines/tidy.md" "see .claude/skills/tidy/scripts/foo.sh"

assert_legal "pure self-cite still legal under per-cite filter" \
  ".claude/skills/tidy/SKILL.md" "see .claude/skills/tidy/context/self.md"

# --- Kill switch: when disabled, exits 0 with no violation message ---
KILL_REPO=$(setup_repo ".claude/routines/unrelated.md" "see .claude/skills/tidy/context/foo.md")
kill_rc=0
kill_out=$(cd "$KILL_REPO" && HOOK_SKILL_ENCAPSULATION_CHECK_ENABLED=false bash "$HOOK" 2>&1) || kill_rc=$?
assert_exit "kill switch exits 0" 0 "$kill_rc"
assert_not_contains "kill switch suppresses violation msg" "$kill_out" "violation(s) found"

[[ $FAILED -eq 0 ]] || exit 1
echo "All $CASE_NUM cases passed."
