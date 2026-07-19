#!/usr/bin/env bash
# Skill verification gate for the skill-improvements rewrite pass.
#
# Static checks per skill — NO model invocation (this repo ships no eval runner,
# per skill/evaluations.md "Anthropic stance on running evals"). The
# keyword-preservation check (check 3) is the regression-critical safety net
# that substitutes for a triggering eval: a rewrite that silently drops a
# `description` trigger phrase degrades auto-invocation, and that is the
# primary risk of the rewrite pass (PLAN.md "Blast radius").
#
# Exit 0 = all checks pass; 1 = one or more check failures; 2 = usage/env error.
#
# Usage:
#   bash tools/skill-verify/check-skill.sh <skill-name>
#   bash tools/skill-verify/check-skill.sh --help
#
# Checks (per skill-improvements Phase 2 + the rewrite bar — git log -- .work/skill-improvements/):
#   1. Frontmatter parses; name + description present
#   2. description+when_to_use combined <= 1536 chars (maxSkillDescriptionChars listing-truncation guard)
#   3. Trigger-keyword preservation vs `git show HEAD:` (skipped for new skills)
#   4. SKILL.md < 500 lines (hard cap)
#   5. Backtick-cited skill-internal supporting files resolve
#   6. markdownlint clean (markdownlint-cli2; WARN-skip if npx absent)
#   7. scripts/*.test.sh pass where present
#   8. vendor/ byte-identical vs HEAD (vendor-backed skills only)
#   9. Stale-tracking metadata keys preserved vs HEAD (upstream-version/synced/upstream-sha)
#  10. SKILL.md <= 200 lines soft target (WARN; skill/architecture.md progressive disclosure)
#  11. Gotchas surface present (WARN; inline `## Gotchas` or context|reference/gotchas.md)
#  12. description carries "Use when" trigger phrasing (WARN)
#  13. No committed cache/build artifacts (__pycache__, *.pyc, node_modules) (FAIL)
#  14. Action-router-shaped skill ships evals/evals.json (WARN; warrant call stays judgment)
#  15. Companion spoke dirs referenced from SKILL.md (WARN; orphan-spoke direction)
#  16. metadata.category present (INFO only)
#  17. Vendor-backed: metadata.synced not older than 180 days (WARN)

set -uo pipefail

# Locally-owned materialization: this checker is also published in the skill-quality
# plugin (melodic-software/claude-code-plugins). It stays in-repo because the
# check-skill-staged lefthook lane invokes it by repo-relative path inside a git hook;
# the plugin exposes the checker only via the /skill-quality:skill-quality skill and a
# CLAUDE_PLUGIN_ROOT scripts dir, neither reachable non-interactively. Logic changes
# belong upstream in the plugin, not in this local copy.

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
  printf 'Error: not in a git repo\n' >&2
  exit 2
fi

# shellcheck source=../skill-contract/skill-frontmatter.sh
source "$REPO_ROOT/tools/skill-contract/skill-frontmatter.sh"

SKILL_NAME="${1:?Usage: check-skill.sh <skill-name>}"
SKILLS_ROOT="${CHECK_SKILL_SKILLS_ROOT:-$REPO_ROOT/.claude/skills}"
SKILL_DIR="$SKILLS_ROOT/$SKILL_NAME"
SKILL_MD="$SKILL_DIR/SKILL.md"
SKILL_REL=".claude/skills/$SKILL_NAME"

# Tunables (maxSkillDescriptionChars cap; SKILL.md line caps; vendor sync age).
DESC_CHAR_CAP=1536
LINE_HARD_CAP=500
LINE_SOFT_CAP=200
SYNCED_MAX_AGE_DAYS=180

FAILED=0
WARNINGS=0

err() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILED=$((FAILED + 1))
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
  WARNINGS=$((WARNINGS + 1))
}

note() {
  printf 'INFO: %s\n' "$*"
}

if [[ ! -d "$SKILL_DIR" ]]; then
  err "Skill not found: $SKILL_DIR"
  exit 1
fi
if [[ ! -f "$SKILL_MD" ]]; then
  err "SKILL.md not found: $SKILL_MD"
  exit 1
fi

# --- Check 1: frontmatter parses; name + description present ---------------

FRONTMATTER="$(skill_frontmatter::extract <"$SKILL_MD")"
if [[ -z "$FRONTMATTER" ]]; then
  err "no YAML frontmatter block found (expected content between two '---' fences)"
else
  grep -qE '^name:[[:space:]]*\S' <<<"$FRONTMATTER" || err "frontmatter missing 'name:'"
  grep -qE '^description:[[:space:]]*\S' <<<"$FRONTMATTER" || err "frontmatter missing 'description:'"
fi

# --- Check 2: description + when_to_use <= DESC_CHAR_CAP chars --------------
# Cap is per-skill listing entry (description + when_to_use combined), per
# skill/architecture.md "Skill-listing budget" (maxSkillDescriptionChars).

CUR_DESC="$(skill_frontmatter::strip_quotes "$(skill_frontmatter::field description <<<"$FRONTMATTER")")"
CUR_WTU="$(skill_frontmatter::strip_quotes "$(skill_frontmatter::field when_to_use <<<"$FRONTMATTER")")"
DESC_LEN=${#CUR_DESC}
WTU_LEN=${#CUR_WTU}
COMBINED_LEN=$((DESC_LEN + WTU_LEN))
if ((COMBINED_LEN > DESC_CHAR_CAP)); then
  err "description+when_to_use is $COMBINED_LEN chars (cap $DESC_CHAR_CAP — overflow truncates the listing)"
elif ((WTU_LEN > 0)); then
  note "description+when_to_use $COMBINED_LEN/$DESC_CHAR_CAP chars (desc $DESC_LEN + when_to_use $WTU_LEN)"
else
  note "description length $DESC_LEN/$DESC_CHAR_CAP chars"
fi

# --- Check 3: trigger-keyword preservation vs HEAD -------------------------

if git -C "$REPO_ROOT" cat-file -e "HEAD:$SKILL_REL/SKILL.md" 2>/dev/null; then
  HEAD_FM_3="$(git -C "$REPO_ROOT" show "HEAD:$SKILL_REL/SKILL.md" 2>/dev/null | skill_frontmatter::extract)"
  HEAD_DESC="$(skill_frontmatter::strip_quotes "$(skill_frontmatter::field description <<<"$HEAD_FM_3")")"
  HEAD_WTU="$(skill_frontmatter::strip_quotes "$(skill_frontmatter::field when_to_use <<<"$HEAD_FM_3")")"
  HEAD_TRIG="$(printf '%s\n%s\n' "$HEAD_DESC" "$HEAD_WTU" | skill_frontmatter::extract_triggers)"
  CUR_TRIG="$(printf '%s\n%s\n' "$CUR_DESC" "$CUR_WTU" | skill_frontmatter::extract_triggers)"
  if [[ -n "$HEAD_TRIG" ]]; then
    MISSING="$(comm -23 <(printf '%s\n' "$HEAD_TRIG") <(printf '%s\n' "$CUR_TRIG"))"
    if [[ -n "$MISSING" ]]; then
      err "dropped trigger keyword(s) vs HEAD (auto-invocation regression): $(printf '%s' "$MISSING" | tr '\n' ' ')"
    else
      note "all $(printf '%s\n' "$HEAD_TRIG" | grep -c .) HEAD trigger phrase(s) preserved"
    fi
  fi
else
  note "no HEAD version (new skill) — keyword-preservation check skipped"
fi

# --- Check 4: SKILL.md < LINE_HARD_CAP lines -------------------------------

LINE_COUNT="$(grep -c '' "$SKILL_MD")"
if ((LINE_COUNT >= LINE_HARD_CAP)); then
  err "SKILL.md is $LINE_COUNT lines (hard cap $LINE_HARD_CAP)"
else
  note "SKILL.md $LINE_COUNT/$LINE_HARD_CAP lines"
fi

# --- Check 5: skill-internal supporting files resolve ----------------------

# Match BOTH backtick refs (`context/foo.md`) AND markdown-link refs
# ([label](context/foo.md#anchor)) into known skill-internal dirs. Scoping to
# these dir names avoids matching prose-example or `.work/<slug>/` paths;
# link-form `#anchor` suffixes are stripped before the existence check.
# Process substitution (not a pipe) keeps the loop in this shell so `err`
# increments FAILED.
#
# Known false-positive classes — do NOT loosen the gate to auto-skip a LITERAL
# path: auto-skipping would MASK a real broken ref. For these, hand-verify the
# cited line (the FAIL message points at SKILL.md:<line>):
#   (a) illustrative example path shown as a FORM, not a real file — prefer
#       rewriting to placeholder form (`reference/<file>.md`), which class (d) ignores
#   (b) exclusion-list glob naming a skip-pattern, not a file — prefer glob
#       form with `*` (`references/data/**`), which the char class ignores
#   (c) cross-skill mention of ANOTHER skill's file, which can't resolve under
#       this skill's own dir (playwright naming /test's `context/e2e.md`)
#   (d) placeholder-segment path (`context/<topic>.md`) — already ignored: the
#       grep char-class below excludes `<` `>`, so it never enters this loop
# The ONE class safe to auto-skip is a gitignored runtime-output path: a
# gitignored path is by definition NOT a tracked supporting file, so skipping
# it cannot mask a real tracked ref.
INTERNAL_DIRS='context|templates|scripts|reference|references|actions|evals|lanes|catalog|vendor'
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  # Auto-skip gitignored runtime-output paths. check-ignore exits 0 only when
  # the path is ignored; 1 (tracked) or 128 (outside the work tree, e.g. the
  # mktemp test fixtures) leave the skip un-fired, so this branch is validated
  # by a live run on a real skill, not by the out-of-repo fixtures.
  if git -C "$REPO_ROOT" check-ignore -q "$SKILL_DIR/$ref" 2>/dev/null; then
    note "check-5 skip (gitignored runtime path): $ref"
    continue
  fi
  if [[ ! -e "$SKILL_DIR/$ref" ]]; then
    ref_line="$(grep -nF "$ref" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)"
    err "broken skill-internal ref: $ref (no such file under $SKILL_REL/; cited at SKILL.md:${ref_line:-?} — hand-verify the line before fixing, may be an illustrative example)"
  fi
done < <(
  {
    grep -oE "\`($INTERNAL_DIRS)/[A-Za-z0-9._/-]+\`" "$SKILL_MD" 2>/dev/null | tr -d '`'
    grep -oE "\]\(($INTERNAL_DIRS)/[A-Za-z0-9._/#-]+\)" "$SKILL_MD" 2>/dev/null \
      | sed -E 's/^\]\(//; s/\)$//; s/#.*$//'
  } | sort -u
)

# --- Check 6: markdownlint clean -------------------------------------------

# CHECK_SKILL_SKIP_MARKDOWNLINT=1 is a test seam: fixture SKILL.md files live
# outside the repo (TEST_TMPDIR), so markdownlint-cli2 finds no repo config and
# applies defaults (MD041/MD013) that real CC skills intentionally violate.
# Real runs leave it unset; markdownlint is also enforced by the markdown-format
# PostToolUse hook on every write.
if [[ "${CHECK_SKILL_SKIP_MARKDOWNLINT:-}" == "1" ]]; then
  note "markdownlint check skipped (CHECK_SKILL_SKIP_MARKDOWNLINT=1)"
elif command -v npx >/dev/null 2>&1; then
  if ! ML_OUT="$(npx markdownlint-cli2 "$SKILL_MD" 2>&1)"; then
    err "markdownlint failed:
$(printf '%s\n' "$ML_OUT" | grep -E '^\S+:[0-9]+' | head -10)"
  else
    note "markdownlint clean"
  fi
else
  warn "npx not found — markdownlint check skipped"
fi

# --- Check 7: scripts/*.test.sh pass where present -------------------------

if [[ -d "$SKILL_DIR/scripts" ]]; then
  while IFS= read -r test_sh; do
    [[ -z "$test_sh" ]] && continue
    # env -u: this gate runs inside git-hook chains (check-skill-staged lane)
    # where git exports GIT_DIR/GIT_INDEX_FILE — a fixture `git init` in a test
    # would then mutate the REAL repo (incident 2026-07-03). Strip before exec.
    if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_PREFIX \
      bash "$test_sh" >/dev/null 2>&1; then
      note "script test passed: ${test_sh#"$SKILL_DIR"/}"
    else
      err "script test failed: ${test_sh#"$SKILL_DIR"/}"
    fi
  done < <(find "$SKILL_DIR/scripts" -name '*.test.sh' -type f 2>/dev/null | sort)
fi

# --- Check 8: vendor/ byte-identical vs HEAD (vendor-backed only) ----------

if [[ -d "$SKILL_DIR/vendor" ]]; then
  if git -C "$REPO_ROOT" diff --quiet HEAD -- "$SKILL_REL/vendor/" 2>/dev/null; then
    note "vendor/ unchanged vs HEAD"
  else
    err "vendor/ changed vs HEAD — byte-identical guarantee (skill/vendoring.md 'Verbatim guarantee'); rewrites must not touch vendor/"
  fi
fi

# --- Check 9: stale-tracking metadata keys preserved vs HEAD ---------------

if git -C "$REPO_ROOT" cat-file -e "HEAD:$SKILL_REL/SKILL.md" 2>/dev/null; then
  HEAD_FM="$(git -C "$REPO_ROOT" show "HEAD:$SKILL_REL/SKILL.md" 2>/dev/null | skill_frontmatter::extract)"
  for key in upstream-version synced upstream-sha; do
    if grep -qE "^[[:space:]]*$key:" <<<"$HEAD_FM"; then
      grep -qE "^[[:space:]]*$key:" <<<"$FRONTMATTER" \
        || err "metadata key '$key' present at HEAD but dropped (stale-tracking — skill/vendoring.md)"
    fi
  done
fi

# --- Check 10: SKILL.md soft line target (progressive disclosure) ----------

if ((LINE_COUNT > LINE_SOFT_CAP && LINE_COUNT < LINE_HARD_CAP)); then
  warn "SKILL.md is $LINE_COUNT lines (soft target $LINE_SOFT_CAP — consider pushing detail to spokes per skill/architecture.md)"
fi

# --- Check 11: Gotchas surface present --------------------------------------

if ! grep -qEi '^##+[[:space:]]+(gotchas|quirks)' "$SKILL_MD" \
  && [[ ! -f "$SKILL_DIR/context/gotchas.md" ]] \
  && [[ ! -f "$SKILL_DIR/reference/gotchas.md" ]] \
  && [[ ! -f "$SKILL_DIR/references/gotchas.md" ]]; then
  warn "no Gotchas surface (inline '## Gotchas' or context/gotchas.md) — confirm the skill has no observed failure history (skill/architecture.md 'SKILL.md body')"
fi

# --- Check 12: description carries trigger phrasing --------------------------

if [[ -n "$CUR_DESC" ]] && ! grep -qi 'use when' <<<"$CUR_DESC$CUR_WTU"; then
  warn "description has no 'Use when:' trigger phrasing — description is a trigger spec, not a summary (skill/architecture.md frontmatter policy)"
fi

# --- Check 13: no committed cache/build artifacts ----------------------------

CACHE_HITS="$(git -C "$REPO_ROOT" ls-files "$SKILL_REL" 2>/dev/null | grep -E '__pycache__|\.pyc$|/node_modules/' || true)"
if [[ -n "$CACHE_HITS" ]]; then
  err "committed cache/build artifact(s) under $SKILL_REL: $(printf '%s' "$CACHE_HITS" | head -3 | tr '\n' ' ')"
fi

# --- Check 14: action-router shape without evals ------------------------------

if grep -qE '^##+[[:space:]]+Actions?\b' "$SKILL_MD" && [[ ! -f "$SKILL_DIR/evals/evals.json" ]]; then
  warn "action-router-shaped skill with no evals/evals.json — check the warrant per skill/evaluations.md 'When to ship evals'"
fi

# --- Check 15: companion spoke dirs referenced from the hub -------------------

for spoke_dir in context reference references templates lanes actions; do
  [[ -d "$SKILL_DIR/$spoke_dir" ]] || continue
  grep -q "$spoke_dir/" "$SKILL_MD" \
    || warn "orphan spoke: $spoke_dir/ exists but SKILL.md never references it (progressive-disclosure routing gap)"
done

# --- Check 16: metadata.category (informational) ------------------------------

if [[ -n "$FRONTMATTER" ]] && ! grep -A8 '^metadata:' <<<"$FRONTMATTER" | grep -q 'category:'; then
  note "no metadata.category in frontmatter (optional — category not machine-readable)"
fi

# --- Check 17: vendor sync age ------------------------------------------------

if [[ -d "$SKILL_DIR/vendor" ]]; then
  SYNCED_VAL="$(awk '/^metadata:/{m=1;next} m && /^[a-zA-Z]/{m=0} m && /^[[:space:]]+synced:/{print $2;exit}' <<<"$FRONTMATTER" | tr -d '"' | tr -d "'")"
  if [[ "$SYNCED_VAL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    if SYNCED_EPOCH="$(date -u -d "$SYNCED_VAL" +%s 2>/dev/null)"; then
      AGE_DAYS=$((($(date -u +%s) - SYNCED_EPOCH) / 86400))
      if ((AGE_DAYS > SYNCED_MAX_AGE_DAYS)); then
        warn "vendor last synced $AGE_DAYS days ago (> $SYNCED_MAX_AGE_DAYS) — run the skill's update action (skill/vendoring.md)"
      fi
    fi
  fi
fi

# --- Summary ---------------------------------------------------------------

printf '\n'
if ((FAILED > 0)); then
  printf 'CHECK-SKILL %s: FAIL — %d error(s), %d warning(s)\n' "$SKILL_NAME" "$FAILED" "$WARNINGS" >&2
  exit 1
fi
printf 'CHECK-SKILL %s: PASS — 0 errors, %d warning(s)\n' "$SKILL_NAME" "$WARNINGS"
exit 0
