#!/usr/bin/env bash
# Pre-commit guard: no external file may cite a skill's private body.
#
# Public surface (cite externally — per `skill/encapsulation.md` "Public surface contract"):
#   - SKILL.md frontmatter (Anthropic-documented fields + `metadata:` block)
#   - Documented actions + arguments/flags
#   - `/skill-name` slash invocation
#   - `<X>/scripts/<entry>` — the skill's declared ENTRY surface (T7b
#     entry-surface carve-out, see below)
#
# Private — everything else inside `.claude/skills/<X>/`: any OTHER subdir
# (regardless of name), any `*.schema.json` at any depth, any SKILL.md
# heading anchor. External consumers MUST NOT cite into the private body;
# the skill body chooses which file/script/schema to use.
#
# scripts/ entry-surface carve-out + inbound/outbound asymmetry (T7b):
#   `<X>/scripts/` is the skill's entry surface per skill/encapsulation.md
#   "Public surface contract" + "CI / git-hook consumption — entry surface,
#   not internals". Harness / CI / hooks / lefthook lanes / workflow
#   registries MAY path-cite a skill's entry scripts directly, so this
#   inbound gate does NOT flag `<X>/scripts/...` cites from ANY external
#   citer. The skill→skill half of the asymmetry — a sibling SKILL.md citing
#   another skill's scripts/ must stay slash-only — is enforced by
#   outbound-direction-check.sh V2 (`docs/conventions/unit-anatomy.md`
#   "Reference budget"), NOT here. Splitting it this way keeps the two gates
#   from double-flagging the same cite.
#
# Scope: rules, routines, automations, agents, workflows, docs, CI, lefthook, root docs,
#        AND skill SKILL.md files for cross-skill citations.
#        NOT checked: private body files (context/, reference/, etc.) — they are impl detail.
#
# LEGAL hits (not flagged):
#   - Self-citation: .claude/skills/<X>/SKILL.md cites .claude/skills/<X>/...
#   - KIND-1 meta-prose: files that describe the encapsulation contract itself
#     (skill/architecture.md, verify-evidence-contract.md, etc.) or document
#     skill internals as worked examples (powershell/conventions.md, etc.).
#   - KIND-2 forced-cite: another hook / GitHub Actions semantic structurally
#     requires the verbatim citation (editorconfig.md rationale-drift hook,
#     onboard-drift.yml `paths:` triggers, onboard-schema-drift.sh canonical vs
#     vendored pair, etc.).
#   - KIND-3 self-test: this hook's own regression fixtures embed literal
#     violation strings as fixtures; they exercise the filter, not real cites.
#
# Kill switch: HOOK_SKILL_ENCAPSULATION_CHECK_ENABLED=false skips entirely.
#
# Tripwire (kind-based, not count-based): when a NEW KIND of structurally-
# inapplicable file appears that doesn't fit any existing kind (meta-prose /
# forced-cite / self-test — see the case statement's section headers), the
# encapsulation RULE needs revision — escalate. Adding another entry to an
# existing kind is fine; the list will grow as new meta-prose / forced cites
# / hook self-tests are added, and that's expected.
#
# SSOT: .claude/rules/skill/encapsulation.md "Public surface contract"
#       (scripts/ carve-out + asymmetry: same file "CI / git-hook consumption
#       — entry surface, not internals"; outbound half: outbound-direction-check.sh)

set -uo pipefail

if [[ "${HOOK_SKILL_ENCAPSULATION_CHECK_ENABLED:-true}" != "true" ]]; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Only run when a file in scan scope is staged. Must match the scan-scope
# list below (rules, routines, automations, agents, workflows, .github,
# .lefthook, docs, root docs) or else a citation in a workflow / hook / root
# doc bypasses the check.
if ! git diff --cached --name-only | grep -qE \
  '^(\.claude/(skills|rules|routines|agents|workflows)/|automations/|\.github/|\.lefthook/|AGENTS\.md|CLAUDE\.md|README\.md|REVIEW\.md|lefthook\.yml|docs/)'; then
  exit 0
fi

# PRIVATE_RE covers all skill-private surfaces per skill/architecture.md
# "Public surface contract": any subdir under a skill root + *.schema.json
# at any depth + SKILL.md heading-anchor cites.
#
# Three alternations:
#   1. `<skill>/<subdir>/`         — any author-chosen subdir name
#   2. `<skill>/SKILL.md#<anchor>` — heading-anchor cites (body structure is private)
#   3. `<skill>/<file>.schema.json` — schema files at any depth
#
# Subdir char class `[a-z][a-z0-9_-]+` matches kebab-style names (consistent
# with skill names themselves). DOES NOT match `SKILL.md` (uppercase) so bare
# `<skill>/SKILL.md` path cites pass (discouraged-but-legal per Phase 1).
# DOES NOT match plain-JSON data files at skill root (`<skill>/catalog.json`)
# — per the data-file carve-out in skill/encapsulation.md "Public surface
# contract", data files retain their canonical path.
PRIVATE_RE='\.claude/skills/[a-z][a-z0-9-]+/[a-z][a-z0-9_-]+/|\.claude/skills/[a-z][a-z0-9-]+/SKILL\.md#|\.claude/skills/[a-z][a-z0-9-]+/[^/]+\.schema\.json'
RELATIVE_RE='\.\./skills/[a-z][a-z0-9-]+/[a-z][a-z0-9_-]+/|\.\./skills/[a-z][a-z0-9-]+/SKILL\.md#|\.\./skills/[a-z][a-z0-9-]+/[^/]+\.schema\.json'

# Run grep relative to REPO_ROOT so all paths are consistent relative paths
(
  cd "$REPO_ROOT" || exit 1

  # External scope: rules, routines, agents, workflows, docs, CI, lefthook, root files.
  # `*.js` is included so `.claude/workflows/*.js` engines are scanned — without it
  # a workflow engine could cite skill internals by path undetected.
  #
  # `-o` (per-cite emission): grep prints ONE record per matched cite, not the
  # whole line. This is the masking fix (gates/DEVIATIONS Phase 2) — a line
  # citing BOTH an exempt surface (a skill's own path, or a <X>/scripts/ entry
  # script) AND a genuine other-skill private subdir now yields two records, so
  # the self-citation + scripts/ filters below evaluate each cite individually;
  # a whole-line `continue` can no longer drop a co-located violation. One
  # batched grep pass (no per-line subprocess), so the Windows fork budget is
  # unchanged from the prior whole-line scan.
  grep -rno -E "${PRIVATE_RE}|${RELATIVE_RE}" \
    --include='*.md' --include='*.sh' --include='*.json' --include='*.yml' --include='*.yaml' --include='*.js' \
    .claude/rules/ .claude/routines/ automations/ .claude/agents/ .claude/workflows/ .github/ docs/ .lefthook/ \
    AGENTS.md CLAUDE.md README.md REVIEW.md lefthook.yml 2>/dev/null

  # Cross-skill scope: SKILL.md files only (not private bodies). Match BOTH
  # absolute `.claude/skills/<x>/...` and relative `../skills/<x>/...` forms
  # since rule files cite via relative paths but SKILL.md typically uses
  # absolute paths. Guarded against missing `.claude/skills/` (test fixtures);
  # `xargs -r` no-ops when grep finds nothing so a clean tree returns 0 not 123.
  if [[ -d .claude/skills ]]; then
    # shellcheck disable=SC2038
    # (skill paths are kebab-case lowercase — no spaces / special chars)
    find .claude/skills -name "SKILL.md" 2>/dev/null \
      | xargs -r grep -lnE "${PRIVATE_RE}|${RELATIVE_RE}" 2>/dev/null \
      | while IFS= read -r skill_file; do
        # `-o` per-cite emission, same masking-fix rationale as the external grep above.
        grep -no -E "${PRIVATE_RE}|${RELATIVE_RE}" "$skill_file" | sed "s|^|${skill_file}:|"
      done
  fi
) | while IFS= read -r line; do
  # Parse `path:lineno:content` via bash parameter expansion (zero forks
  # per line). Original `echo | cut -d: -f<N>` form cost ~6 forks per line
  # × ~30ms Windows fork floor = ~22s on a 119-line scan. See
  # `docs/ecosystems/bash-gotchas-reference.md` "Process spawning overhead on Windows".
  rel_filepath="${line%%:*}"
  rest="${line#*:}"
  linenum="${rest%%:*}"
  content="${rest#*:}"

  # --- FILTER: structurally-inapplicable files (grouped by KIND) ---
  # Tripwire fires when a NEW KIND appears below, not when an existing kind
  # grows. See header "Tripwire" comment.
  case "$rel_filepath" in
    # KIND-1: Meta-prose — files that describe / audit the encapsulation
    # contract itself, OR document skill internals as worked examples /
    # historical narrative / empirically-verified quirks. They reference
    # paths as descriptive data, not as content dependencies that break if
    # the skill refactors.
    #
    # self-cite: detector excluding its own skill from audit (legal — the
    # encapsulation-audit skill IS the audit and authors its own self-
    # references). KIND-1 entry retained per A3 annotation.
    .claude/skills/encapsulation-audit/*) continue ;;
    .claude/rules/skill/architecture.md) continue ;;
    .claude/rules/skill/vendoring.md) continue ;;
    .claude/rules/skill/encapsulation.md) continue ;;
    .claude/rules/verify-evidence-contract.md) continue ;;
    docs/ecosystems/tooling-deferred.md) continue ;;
    docs/ecosystems/tooling-deferred-rows.md) continue ;;
    .claude/rules/skill/quirks.md) continue ;;
    .claude/rules/powershell/conventions.md) continue ;;
    docs/ecosystems/powershell-reference.md) continue ;;
    REVIEW.md) continue ;;
    # KIND-2: Forced cite — another tool / GitHub Actions semantic
    # structurally requires the verbatim citation.
    #
    # editorconfig.md's rationale-drift pre-commit hook requires every
    # .editorconfig-checker.json Exclude regex to appear verbatim here.
    .claude/rules/editorconfig.md) continue ;;
    # drift-marker-check.sh structurally requires excluding skill-cached
    # third-party content from its scan. course-digest's `data/` stores
    # extracted transcripts/frames where quoted source material may contain
    # drift-marker-shaped strings (dates, "removed" verbs) that are content,
    # not repo-internal tombstones. Same precedent as editorconfig.md —
    # another hook structurally requires naming a skill-private path.
    .lefthook/pre-commit/drift-marker-check.sh) continue ;;
    # onboard-drift.yml `paths:` triggers + sparse-checkout structurally need
    # skill-canonical paths so GitHub Actions fires when writer-side files
    # change (paths: watches the CHANGED file, not the file read at runtime).
    # CI invokes the skill-canonical check-update.sh entry directly (inbound
    # asymmetry). See skill/encapsulation.md "CI / git-hook consumption — entry surface, not internals".
    .github/workflows/onboard-drift.yml) continue ;;
    # shell-lint.yml Pester job consumes machine-health skill test
    # infrastructure as full-checkout (Technique 1 — intentional duplication
    # per skill/encapsulation.md "CI / git-hook sharing"). Path-trigger + sparse-checkout
    # cites are structurally required for the workflow to run.
    .github/workflows/shell-lint.yml) continue ;;
    # ci-status.yml ecosystem-detection regex enumerates machine-health
    # Pester config path (Technique 1). Single-line regex membership;
    # alignment cost trivial.
    .github/workflows/ci-status.yml) continue ;;
    # lefthook.yml onboard-catalog-schema lane glob is a mechanical trigger
    # that must cite the skill-canonical catalog data path (catalog.json at
    # the skill root) so the lane fires when that file changes — lefthook
    # resolves lanes by file glob, not slash invocation. Same forced-cite
    # class as onboard-drift.yml paths: + shell-lint.yml sparse-checkout.
    # Whole-file exempt (multi-lane config, shell-lint.yml precedent).
    lefthook.yml) continue ;;
    # onboard-schema-drift.sh body STRUCTURALLY cites both skill-canonical and
    # vendored paths — its sole job is comparing the pair via diff -q. The
    # cite IS the drift-gate's contract.
    .lefthook/pre-commit/onboard-schema-drift.sh) continue ;;
    # roster-sync-check.sh body STRUCTURALLY cites code-review-fanout's
    # run-everything-mode.md + leaf-roster.md — its sole job is diffing the
    # baked OWNERLESS_SLICES array against the roster SSOT. Same forced-cite
    # class as onboard-schema-drift.sh: a drift gate must read the files it guards.
    .lefthook/pre-commit/roster-sync-check.sh) continue ;;
    # KIND-3: Self-test fixtures — regression tests embed literal violation
    # strings as fixtures. They exercise filter behavior; they are not real
    # citations.
    tools/skill-contract/skill-encapsulation-check.test.sh) continue ;;
    # onboard-schema-drift.test.sh fixtures cite skill-canonical paths to
    # exercise the drift-gate against real path shapes. Self-test by the
    # same shape as skill-encapsulation-check.test.sh.
    .lefthook/pre-commit/onboard-schema-drift.test.sh) continue ;;
    # skill-script-contract-check.test.sh seeds throwaway git repos with
    # fake skill paths (sample/scripts/*) to exercise the contract checker
    # against synthetic skill structures. KIND-3 self-test fixtures, not
    # real skill cites.
    tools/skill-contract/skill-script-contract-check.test.sh) continue ;;
    tools/skill-contract/skill-contract-check.test.sh) continue ;;
    # markdown-link-check.test.sh seeds a throwaway git repo with a fake-skill
    # vendor path to exercise the markdown-link gate's vendor-exclusion case.
    # KIND-3 self-test fixture by the same shape as the entries above — fake
    # skill, not a real cite. (Path not spelled literally here so this comment
    # does not itself trip the gate's broad scan.)
    .lefthook/pre-commit/markdown-link-check.test.sh) continue ;;
  esac

  # --- FILTER: self-citation (skill cites its own private surface) ---
  # Bash `[[ =~ ]]` (no fork) replaces `echo | grep -qE` + `echo | sed`;
  # `*pattern*` glob replaces second `echo | grep -qE`. Same hot-loop
  # rationale as the parse-via-parameter-expansion above.
  if [[ "$rel_filepath" =~ ^\.claude/skills/([a-z][a-z0-9-]+)/ ]]; then
    citing_skill="${BASH_REMATCH[1]}"
    if [[ "$content" == *".claude/skills/${citing_skill}/"* ]]; then
      continue
    fi
  fi

  # --- FILTER: scripts/ entry-surface carve-out (T7b) ---
  # A skill's `scripts/` is its declared ENTRY surface per
  # skill/encapsulation.md "Public surface contract": harness / CI / hooks /
  # lefthook lanes / workflow registries MAY path-cite a skill's entry scripts
  # directly. This inbound gate therefore does NOT flag `<X>/scripts/...` cites
  # from any external citer. The skill→skill half of the asymmetry (a sibling
  # SKILL.md citing another skill's scripts/ stays slash-only) is enforced by
  # outbound-direction-check.sh V2, NOT here — keeping the two gates from
  # double-flagging the same cite. PRIVATE_RE still matches scripts/ so the
  # scan grep emits a record for it (bash ERE has no lookahead to exclude one
  # subdir name); the carve-out is this post-match filter, applied per-cite
  # because the scan grep's `-o` splits each line into one record per cite.
  # Skill name `[a-z][a-z0-9-]+` carries no slash, so the match is one
  # contiguous `<X>/scripts/` segment — same per-cite scope as the
  # self-citation filter above (no fork).
  if [[ "$content" =~ \.claude/skills/[a-z][a-z0-9-]+/scripts/ ]] \
    || [[ "$content" =~ \.\./skills/[a-z][a-z0-9-]+/scripts/ ]]; then
    continue
  fi

  echo "${rel_filepath}:${linenum}: ${content}"
done | {
  violations=()
  while IFS= read -r v; do
    violations+=("$v")
  done

  if [[ ${#violations[@]} -eq 0 ]]; then
    exit 0
  fi

  echo "skill-encapsulation-check: ${#violations[@]} violation(s) found."
  echo "External files must not cite any subdir or *.schema.json inside .claude/skills/<X>/."
  echo "See .claude/rules/skill/architecture.md 'Public surface contract' for remediation (Path A or Path B)."
  echo ""
  for v in "${violations[@]}"; do
    echo "  $v"
  done
  echo ""
  echo "Fix violations before committing. If a new exception is needed, the encapsulation RULE needs revision — do not silently extend this filter."
  exit 1
}
