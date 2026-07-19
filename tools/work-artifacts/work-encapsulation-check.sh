#!/usr/bin/env bash
# Pre-commit gate: detect concrete `.work/<slug>/<path>` pointers in tracked
# files OUTSIDE `.work/`. Codifies the encapsulation invariant (Boundary A):
# nothing durable may point at a specific slice's LIVE content, because slices
# are sealed, non-long-lived units that dangle on deletion. Enforcement-hierarchy
# upgrade of `markdown-discipline.md` "Noise shape 2".
#
# Mode: BLOCKING (exit 1 on match). Prints findings to stderr with
# `::warning::` prefix so CI surfaces them before the hook exits non-zero.
#
# Kill switch: HOOK_WORK_ENCAPSULATION_CHECK_ENABLED=false skips the lane.
#
# ALLOWED forms (Boundary A — never flagged):
#   - `git log -- .work/<slug>/` history-retrieval hints (the sanctioned
#     provenance pattern — explicitly signals "gone, retrieve from history")
#   - `.work/<placeholder>/` angle-bracket schema (describes the convention,
#     not a specific slice) — naturally excluded: `<` is not a slug char
#   - `$SLUG` / `${...}` shell-variable forms — naturally excluded
#   - pedagogical example slugs (foo / bar / sample-slice / scratch / ...)
#   - machinery that manages `.work/` (path allow-list below): tools/work-artifacts/*,
#     work-artifacts* rules, push/verify gates, lint configs, *.test.sh fixtures

set -uo pipefail

# Kill switch
if [[ "${HOOK_WORK_ENCAPSULATION_CHECK_ENABLED:-true}" == "false" ]]; then
  exit 0
fi

STAGED_FILES=("$@")
[[ ${#STAGED_FILES[@]} -eq 0 ]] && exit 0

# Pedagogical / placeholder slugs — a `.work/<example>/` pointer teaches the
# convention rather than depending on a live slice. ERE alternation; trailing
# `/` anchor in the neutralizer prevents partial-prefix matches.
EXAMPLE_ALT='foo|bar|baz|qux|sample-slice|scratch|two|test|nofm|slug-no-logs|foo-slice|foo-bar|foo-migration-2026-q1|example|demo|placeholder'

# Core forbidden shape: `.work/<kebab-slug>/` where slug starts [a-z0-9].
FORBIDDEN_RE='\.work/[a-z0-9][a-z0-9-]+/'

# Build the scan set first — drop excluded paths (three skip kinds), then scan
# every remaining staged file in ONE grep (was one spawn per file), mirroring
# drift-marker-check.sh's batched form.
SCAN_FILES=()
for f in "${STAGED_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  base="${f##*/}"

  # Skip list — three kinds (keep section headers; recheck-trigger in
  # cleanliness-regime.md references "case-statement section headers"):
  case "$f" in
    # Slice-internal — out of scope (a slice's own cross-refs are legal)
    .work/* | */.work/*) continue ;;
    # Self — this script + its test embed the forbidden regex as pattern strings
    */work-encapsulation-check.sh) continue ;;
    # Machinery that manages .work/ (Boundary A allow-list)
    *work-artifacts* | .claude/skills/youtube/extraction/*) continue ;;
    */verify-evidence-gate.sh | */hardcoded-path-*.sh) continue ;;
  esac
  case "$base" in
    # Test fixtures legitimately construct representative `.work/...` paths
    *.test.sh) continue ;;
    # Lint configs whose exclude patterns legitimately name `.work/...` paths
    .gitignore | .gitattributes | .editorconfig | .editorconfig-checker.json | _typos.toml | .gitleaks.toml | .markdownlint-cli2.jsonc | .globalconfig | .lycheeignore) continue ;;
  esac

  SCAN_FILES+=("$f")
done

[[ ${#SCAN_FILES[@]} -eq 0 ]] && exit 0

# One batched grep over the whole scan set. `-I` skips binary files (replaces
# the per-file `grep -Iq` NUL probe); `-H` forces the filename prefix so the
# `<file>:<lineno>:<content>` parse is uniform even with a single file.
FINDINGS=0
while IFS= read -r matchline; do
  [[ -z "$matchline" ]] && continue
  # Split "<file>:<lineno>:<content>" (staged paths are repo-relative — no drive
  # colon to confuse the split; content keeps any later colons intact).
  f="${matchline%%:*}"
  rest="${matchline#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"

  # Neutralize ALLOWED forms, then check for any surviving bare pointer.
  # (1) git-log retrieval clauses — the sanctioned provenance form.
  # (2) example/placeholder slugs. Angle-bracket + $var forms are already
  #     excluded by FORBIDDEN_RE (`<` / `$` are not slug chars), so a line
  #     carrying ONLY those never becomes a candidate. The two substitutions are
  #     independent — one `sed -E -e … -e …` invocation, not two piped seds.
  clean=$(sed -E \
    -e 's#git log -- \.work/[a-z0-9][a-z0-9-]*/?##g' \
    -e "s#\.work/($EXAMPLE_ALT)/#.work/__EXAMPLE__/#g" \
    <<<"$content")

  if grep -qE "$FORBIDDEN_RE" <<<"$clean"; then
    echo "::warning file=$f,line=$lineno::work-encapsulation: concrete .work/ slice pointer outside .work/ (Boundary A) — $content" >&2
    FINDINGS=$((FINDINGS + 1))
  fi
done < <(LC_ALL=C grep -InHE "$FORBIDDEN_RE" "${SCAN_FILES[@]}" 2>/dev/null || true)

if [[ $FINDINGS -gt 0 ]]; then
  echo "" >&2
  echo "work-encapsulation-check: $FINDINGS concrete .work/<slug>/ pointer(s) in tracked files outside .work/." >&2
  echo "Rule: encapsulation invariant (Boundary A) — slices are sealed, non-long-lived; durable files must not depend on live slice content." >&2
  echo "Fix: strip/generalize, \`git log -- .work/<slug>/\`, or inline into nearest SSOT — NOT wholesale promotion of slice files. Playbook: work-artifact-reference.md \"Fixing encapsulation violations\"." >&2
  echo "Set HOOK_WORK_ENCAPSULATION_CHECK_ENABLED=false to silence (not recommended)." >&2
  exit 1
fi

exit 0
