#!/usr/bin/env bash
# Contract tests for check-heading-cites.sh. Uses the --corpus-file + --root
# test seam with a fixture corpus so every case is hermetic (no live-repo
# dependence). Not `set -e`: exit codes checked explicitly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CHECKER="${SCRIPT_DIR}/check-heading-cites.sh"

FAILED=0
CASE_NUM=0

# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel | tr -d '\r')/tests/shell/lib.sh"

root="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$root'" EXIT
mkdir -p "$root/docs/sub" "$root/a" "$root/b"

# --- Case 1: --help exits 0 with non-empty stdout ---
help_out="$(bash "$CHECKER" --help 2>&1)"
assert_exit "--help exits 0" 0 "$?"
assert_contains "--help prints usage" "$help_out" "Usage: check-heading-cites.sh"

# --- Fixture: anchor-target file exercising every anchor shape ---
cat >"$root/docs/target.md" <<'EOF'
# Target Doc

## Verify-before-edit rule (mandatory for Tier 3)

Body text.

## `dotnet` CLI quirks

- **Bullet lead** — detail here

**Para lead** — paragraph detail

| Col | Col2 |
|---|---|
| **Cell lead** | x |

## 1. Ordinal heading

**Trailing period.** Sentence-lead bold detail.
EOF

# BOM + CRLF robustness target (defensive against local eol overrides).
printf '\357\273\277# BOM Doc\r\n\r\n## CRLF Anchor\r\n' >"$root/docs/bom.md"

# Fenced-code target: the "heading" inside the fence must NOT be indexed.
# Includes a 4-backtick fence wrapping a 3-backtick block (CommonMark length
# pairing): the inner ``` lines are content, not closers.
cat >"$root/docs/fenced.md" <<'EOF'
# Fenced Doc

```bash
# fence heading
see `missing.md` "Inside Fence"
```

````text
## Inside Long Fence

```bash
echo nested
```

## Still Inside Long Fence
````

## After Long Fence
EOF

# --- Clean corpus: every resolving cite shape + exemptions ---
cat >"$root/docs/clean-citing.md" <<'EOF'
# Clean Citing

Exact path: `docs/target.md` "Target Doc". Truncated prefix: `target.md` "Verify-before-edit rule".
Escaped backticks: `target.md` "\`dotnet\` CLI quirks".
Backtick-stripped cite of a backticked heading: `target.md` "dotnet CLI quirks".
Ordinal-stripped cite: `target.md` "Ordinal heading". Period-stripped cite: `target.md` "Trailing period".
Heading after a 4-backtick fence is a real anchor: `fenced.md` "After Long Fence".
Chained: `target.md` "Bullet lead" + "Para lead" + "Cell lead".
BOM/CRLF target: `bom.md` "CRLF Anchor".
<!-- heading-cite-ignore -->
Exempt next line: `missing.md` "Skipped".
Exempt same line: `missing.md` "AlsoSkipped". <!-- heading-cite-ignore-line -->
Prose form: docs/prose-target.md "Prose Anchor".
Chained prose: docs/target.md "Bullet lead" + "Para lead".
Placeholder forms are regex-invisible: `<placeholder>.md` "Whatever" and `.work/<slug>/PLAN.md` "Schema".
URL prose tail ignored: https://example.com/docs/file.md "External Label".
EOF
cat >"$root/docs/prose-target.md" <<'EOF'
# Prose Target

## Prose Anchor

Body.
EOF
cat >"$root/docs/sub/inner.md" <<'EOF'
# Inner

Relative: `../target.md` "Target Doc".
EOF
cat >"$root/suffix-citer.md" <<'EOF'
# Suffix Citer

Unique suffix from another dir: `target.md` "Target Doc".
EOF
printf '%s\n' docs/target.md docs/bom.md docs/fenced.md docs/prose-target.md \
  docs/clean-citing.md docs/sub/inner.md suffix-citer.md >"$root/clean-corpus.txt"

clean_out="$(bash "$CHECKER" --root "$root" --corpus-file "$root/clean-corpus.txt" 2>&1)"
assert_exit "clean corpus exits 0" 0 "$?"
assert_silent "clean corpus silent stdout" "$clean_out"

# --- Dirty corpus: each failure class flagged, resolving cites not flagged ---
cat >"$root/a/dup.md" <<'EOF'
# Dup A
EOF
cat >"$root/b/dup.md" <<'EOF'
# Dup B
EOF
cat >"$root/docs/dirty-citing.md" <<'EOF'
# Dirty Citing

Dead file: `missing.md` "Anything".
Dead anchor: `target.md` "Nope".
Prose dead file: docs/missing-prose.md "Ghost".
Prose dead anchor: docs/target.md "Prose Nope".
Prefix without delimiter guard: `target.md` "Verify-before".
Ambiguous suffix: `dup.md` "Dup A".
Chained with one dead: `target.md` "Bullet lead" + "Ghost".
Fenced heading is not an anchor: `fenced.md` "fence heading".
Heading inside a 4-backtick fence is not an anchor: `fenced.md` "Inside Long Fence".
URL then dead on same line: https://example.com/docs/file.md "External" docs/missing-url-tail.md "SameLineGhost".
EOF
printf '%s\n' docs/target.md docs/fenced.md a/dup.md b/dup.md \
  docs/dirty-citing.md >"$root/dirty-corpus.txt"

dirty_out="$(bash "$CHECKER" --root "$root" --corpus-file "$root/dirty-corpus.txt" 2>&1)"
assert_exit "dirty corpus exits 1" 1 "$?"
assert_contains "dead-file flagged" "$dirty_out" \
  'docs/dirty-citing.md:3: unresolved cite → missing.md "Anything" (reason: no-file)'
assert_contains "dead-anchor flagged" "$dirty_out" \
  'target.md "Nope" (reason: no-anchor)'
assert_contains "prose dead-file flagged" "$dirty_out" \
  'docs/missing-prose.md "Ghost" (reason: no-file)'
assert_contains "prose dead-anchor flagged" "$dirty_out" \
  'docs/target.md "Prose Nope" (reason: no-anchor)'
assert_contains "prefix-miss (no delimiter) flagged" "$dirty_out" \
  'target.md "Verify-before" (reason: no-anchor)'
assert_contains "ambiguous suffix flagged as no-file" "$dirty_out" \
  'dup.md "Dup A" (reason: no-file)'
assert_contains "dead chained anchor flagged" "$dirty_out" \
  'target.md "Ghost" (reason: no-anchor)'
assert_contains "fenced heading not indexed" "$dirty_out" \
  'fenced.md "fence heading" (reason: no-anchor)'
assert_contains "4-backtick fence interior not indexed" "$dirty_out" \
  'fenced.md "Inside Long Fence" (reason: no-anchor)'
assert_contains "URL-skip does not swallow next prose cite" "$dirty_out" \
  'docs/missing-url-tail.md "SameLineGhost" (reason: no-file)'
assert_not_contains "resolving chained anchor not flagged" "$dirty_out" '"Bullet lead"'
assert_row_count "dirty corpus finding count" "$dirty_out" 10 'unresolved cite'

# --- Renamed-heading detection (the RED-on-rename proof) ---
mkdir -p "$root/rename"
cat >"$root/rename/lib.md" <<'EOF'
# Lib

## Old Name

Body.
EOF
cat >"$root/rename/citer.md" <<'EOF'
# Citer

See `lib.md` "Old Name".
EOF
printf '%s\n' rename/lib.md rename/citer.md >"$root/rename-corpus.txt"

bash "$CHECKER" --root "$root" --corpus-file "$root/rename-corpus.txt" >/dev/null 2>&1
assert_exit "pre-rename corpus green" 0 "$?"

cat >"$root/rename/lib.md" <<'EOF'
# Lib

## New Name

Body.
EOF
rename_out="$(bash "$CHECKER" --root "$root" --corpus-file "$root/rename-corpus.txt" 2>&1)"
assert_exit "heading rename turns gate RED" 1 "$?"
assert_contains "renamed heading flagged at cite site" "$rename_out" \
  'rename/citer.md:3: unresolved cite → lib.md "Old Name" (reason: no-anchor)'

# --- Usage error ---
bash "$CHECKER" --bogus-flag >/dev/null 2>&1
assert_exit "unknown flag exits 2" 2 "$?"

echo "check-heading-cites.test.sh: $((CASE_NUM - FAILED)) passed, ${FAILED} failed"
[[ "$FAILED" -eq 0 ]] || exit 1
