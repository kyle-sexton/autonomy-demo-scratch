#!/usr/bin/env bash
# Contract test for measure.sh. Builds a throwaway git repo so corpus enumeration
# (noise exclusion + primary/secondary split) and the deterministic rerun are hermetic —
# no dependence on the live repo state. Not `set -e`: exit codes are checked explicitly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MEASURE="${SCRIPT_DIR}/measure.sh"

PASS=0
FAIL=0
pass() {
  echo "  ok: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

# --- Test 1: --help exits 0 with non-empty output ---
if help_out="$(bash "$MEASURE" --help 2>&1)" && [[ -n "$help_out" ]]; then
  pass "--help exit 0, non-empty"
else
  fail "--help exit 0, non-empty"
fi

# --- Fixture repo: in-scope, noise, .work, and out-of-scope markdown ---
repo="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$repo'" EXIT
mkdir -p "$repo/.claude/rules" "$repo/docs" "$repo/.work/slice" \
  "$repo/node_modules/pkg" "$repo/.claude/skills/x/data" "$repo/.cursor"
printf '# rule\n\nbody words here for the rule file.\n' >"$repo/.claude/rules/a.md"
printf '# doc\n\nbody words here for the doc file.\n' >"$repo/docs/b.md"
printf '# plan\n\nslice body words here.\n' >"$repo/.work/slice/PLAN.md"
printf '# noise\n' >"$repo/node_modules/pkg/c.md"      # excluded: node_modules
printf '# noise\n' >"$repo/.claude/skills/x/data/d.md" # excluded: skills/*/data
printf '# cursor\n' >"$repo/.cursor/z.md"              # dropped: out of Scope
# Plain init (not -b) + inline identity for cross-platform fixture stability.
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.email=t@example.com -c user.name=tester commit -qm init >/dev/null

# --- Test 2: enumeration excludes noise + splits primary/secondary ---
dry="$(bash "$MEASURE" --root "$repo" --dry-run 2>/dev/null)"
if grep -qE 'primary files:[[:space:]]+2' <<<"$dry" \
  && grep -qE 'secondary files:[[:space:]]+1' <<<"$dry"; then
  pass "noise excluded; primary=2 secondary=1"
else
  fail "enumeration split ($(grep -iE 'primary|secondary' <<<"$dry" | tr '\n' ' '))"
fi

# --- Test 3: two runs at the same HEAD are byte-identical modulo the timestamp ---
# Assert both writes SUCCEED and produce non-empty files before diffing. A failed
# --out (e.g. missing datasketch) leaves no file; without the existence guard the
# diff would compare empty-vs-empty and falsely pass, masking the real failure.
if bash "$MEASURE" --root "$repo" --out "$repo/out_a.md" >/dev/null 2>&1 \
  && bash "$MEASURE" --root "$repo" --out "$repo/out_b.md" >/dev/null 2>&1 \
  && [[ -s "$repo/out_a.md" && -s "$repo/out_b.md" ]] \
  && diff <(grep -v '^generated:' "$repo/out_a.md") \
    <(grep -v '^generated:' "$repo/out_b.md") >/dev/null; then
  pass "deterministic rerun (identical modulo generated)"
else
  fail "deterministic rerun"
fi

# --- Test 4: --since <head_sha> yields an empty co-change forward window ---
head_sha="$(git -C "$repo" rev-parse HEAD | tr -d '\r')"
if bash "$MEASURE" --root "$repo" --since "$head_sha" --out "$repo/out_since.md" >/dev/null 2>&1 \
  && grep -q 'No co-change pairs' "$repo/out_since.md"; then
  pass "--since head_sha: empty forward window"
else
  fail "--since head_sha: empty forward window"
fi

echo "measure.test.sh: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
