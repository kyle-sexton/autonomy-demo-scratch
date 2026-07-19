# shellcheck shell=bash
# Shared corpus-scope patterns for the markdown-coupling detection tools (D8 — Rule-of-Three
# extraction of the markdown-discipline "Scope" primary set + the noise classes).
#
# Library — NOT executable (mode 100644). Pure data: no I/O, no exit, no env reads, no `set`
# (would leak into the caller). Callers compose the enumeration pipe themselves
# (`git ls-files '*.md' | grep -vE "$NOISE_RE" | grep -v '^\.work/' | grep -E "$SCOPE_RE"`) and
# decide the .work/ primary-vs-secondary split — only the two regexes are shared.
#
# Consumers derive on demand via the repo dep-graph edge scan
# (tools/AGENTS.md "Vertical slices" — dep-graph row).
#
# SSOT for the corpus definition is markdown-discipline.md "Scope". When that scope changes,
# edit HERE once — the consumers inherit it (the prior triplication was DEVIATIONS D8).

# Primary instruction-corpus path-classes (markdown-discipline.md "Scope"; durable, non-.work).
# shellcheck disable=SC2034  # consumed by the sourcing scripts, not this lib
SCOPE_RE='^\.claude/rules/.*\.md$|^\.claude/skills/.*\.md$|^docs/.*\.md$|^automations/.*\.md$|(^|/)AGENTS\.md$|(^|/)CLAUDE\.md$|(^|/)README\.md$|^REVIEW\.md$'
# Noise classes the corpus MUST exclude (EXPLORE.md "Noise classes the corpus MUST exclude").
# NOTE: template / eval-fixture content is NOT excluded here — those files are valid CITE
# TARGETS (e.g. `templates/checklist.md` is cited), so the heading-cite resolver (which also
# sources this NOISE_RE) must keep them resolvable. The near-dup advisory skips them lane-locally
# instead (markdown-near-dup-check.sh) — only that consumer treats them as structural noise.
# shellcheck disable=SC2034
NOISE_RE='(^|/)node_modules/|^\.claude/skills/[^/]+/data/|^\.claude/skills/[^/]+/output/|^\.claude/skills/[^/]+/context/runs/|/scaffolds/'
