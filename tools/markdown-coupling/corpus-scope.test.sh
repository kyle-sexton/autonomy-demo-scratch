#!/usr/bin/env bash
# Contract test for corpus-scope.sh — pins the SCOPE_RE / NOISE_RE classification so a
# future edit to the shared SSOT can't silently shift the corpus the two consumers
# (measure.sh, markdown-near-dup-check.sh) enumerate. Not `set -e`:
# classifications are asserted individually.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./corpus-scope.sh
source "$SCRIPT_DIR/corpus-scope.sh"

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# in_scope <path> — true when <path> is a primary-corpus member: matches SCOPE_RE, is NOT
# noise, and is NOT under .work/ (the three-grep pipe the consumers share, primary variant).
in_scope() {
  printf '%s\n' "$1" | grep -vE "$NOISE_RE" | grep -v '^\.work/' | grep -qE "$SCOPE_RE"
}

assert_in_scope() {
  if in_scope "$2"; then pass "$1"; else fail "$1" "in-scope" "excluded"; fi
}
assert_out_of_scope() {
  if in_scope "$2"; then fail "$1" "excluded" "in-scope"; else pass "$1"; fi
}

# Constants are present and non-empty.
assert_eq "SCOPE_RE non-empty" 0 "$([[ -n "$SCOPE_RE" ]] && echo 0 || echo 1)"
assert_eq "NOISE_RE non-empty" 0 "$([[ -n "$NOISE_RE" ]] && echo 0 || echo 1)"

# Primary-corpus members.
assert_in_scope "rules .md in scope" ".claude/rules/work-artifacts/conventions.md"
assert_in_scope "skills SKILL.md in scope" ".claude/skills/handoff/SKILL.md"
assert_in_scope "docs .md in scope" "docs/conventions/prose-compression.md"
assert_in_scope "root AGENTS.md in scope" "AGENTS.md"
assert_in_scope "root CLAUDE.md in scope" "CLAUDE.md"
assert_in_scope "REVIEW.md in scope" "REVIEW.md"
# Per-package READMEs anywhere are in scope — SCOPE_RE's (^|/)README\.md$ matches by design
# (markdown-discipline "Scope"), so a non-rules/skills/docs README still counts.
assert_in_scope "per-package README in scope" "tools/markdown-coupling/README.md"

# Out of scope: non-markdown, unscoped tree, noise, or .work/.
assert_out_of_scope "source .cs excluded" "apps/monolith-api/Program.cs"
assert_out_of_scope "node_modules excluded" "mcp-servers/x/node_modules/readme.md"
assert_out_of_scope "skill data/ excluded" ".claude/skills/foo/data/sample.md"
assert_out_of_scope "skill output/ excluded" ".claude/skills/foo/output/run.md"
assert_out_of_scope "scaffolds excluded" ".claude/skills/foo/scaffolds/template.md"
# templates/ + evals/ are NOT NOISE-excluded (they are valid heading-cite targets) — the
# near-dup advisory skips them lane-locally instead. So they stay IN the shared corpus scope.
assert_in_scope "skill templates stay in shared scope" ".claude/skills/architect/templates/checklist.md"
assert_in_scope "skill eval fixtures stay in shared scope" ".claude/skills/compress/evals/fixtures/mixed-skill-body.md"
assert_out_of_scope ".work slice excluded" ".work/markdown-coupling/PLAN.md"
assert_out_of_scope "sandbox .md excluded" "sandboxes/spike/notes.md"

[[ $FAILED -eq 0 ]] || exit 1
