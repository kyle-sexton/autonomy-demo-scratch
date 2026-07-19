#!/usr/bin/env bash
# Registry drift guard for patterns.registry.tsv
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

REGISTRY="$SCRIPT_DIR/patterns.registry.tsv"
SWEEP="$SCRIPT_DIR/detect-sweep.sh"
FAILED=0

count="$(grep -cve '^#' "$REGISTRY" | tr -d '\r')"
if [[ "$count" -ge 10 ]]; then
  pass "registry has >= 10 pattern forms"
else
  fail "registry has >= 10 pattern forms" ">=10" "$count"
fi

assert_contains "slash-token present" "$(cat "$REGISTRY")" $'slash-token\tcertain'

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

git init "$TEST_TMPDIR/repo" >/dev/null 2>&1
git -C "$TEST_TMPDIR/repo" config user.email "t@example.com"
git -C "$TEST_TMPDIR/repo" config user.name "Test"
mkdir -p "$TEST_TMPDIR/repo/docs"
cat >"$TEST_TMPDIR/repo/docs/pattern-fixture.md" <<'EOF'
/zztesttok workflow
bare zztesttok token
context/zztesttok.md
skills/zztesttok/
zztesttok/SKILL.md
zztesttok/scripts/tool.sh
review, zztesttok next
zztesttok → retro
| 3. zztesttok |
| 3. zztesttok | col |
zztesttok.suffix
EOF
git -C "$TEST_TMPDIR/repo" add docs/pattern-fixture.md
git -C "$TEST_TMPDIR/repo" commit -m "init" >/dev/null

sweep_out="$(GIT_DIR="$TEST_TMPDIR/repo/.git" GIT_WORK_TREE="$TEST_TMPDIR/repo" bash -c \
  "cd '$TEST_TMPDIR/repo' && bash '$SWEEP' --old zztesttok --mode blast")"

while IFS=$'\t' read -r id triage _template; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  pattern_line="$(printf '%s\n' "$sweep_out" | grep -F "Pattern: $id |" | tail -1 || true)"
  if [[ -z "$pattern_line" ]]; then
    fail "pattern $id fires" "Pattern: $id | triage=$triage | hits>=1" "(missing)"
    continue
  fi
  hits="${pattern_line##*hits=}"
  if [[ "$hits" =~ ^[1-9][0-9]*$ ]]; then
    pass "pattern $id fires (hits=$hits)"
  else
    fail "pattern $id fires" "hits>=1" "$pattern_line"
  fi
done <"$REGISTRY"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: patterns.registry.tsv drift test passed"
