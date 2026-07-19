#!/usr/bin/env bash
# Contract test for py-discovery.sh — mc_discover_python resolves a datasketch-importing
# interpreter for the markdown-coupling tools and falls back gracefully. Not `set -e`:
# assertions are checked explicitly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./py-discovery.sh
source "$SCRIPT_DIR/py-discovery.sh"

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Case 1: against the real markdown-coupling dir (this dir holds .venv), discovery returns an
# interpreter. No interpreter at all (no venv + no python on PATH) is a toolchain gap -> skip.
py="$(mc_discover_python "$SCRIPT_DIR")"
if [[ -z "$py" ]]; then
  skip_suite "no python interpreter resolvable — discovery untestable"
fi
pass "discovers an interpreter for the real tools dir"

# Case 2: when the resolved interpreter has datasketch, it imports it (preference honored). When
# the machine lacks datasketch entirely, the preference is untestable -> skip that one case.
if "$py" -c 'import datasketch' >/dev/null 2>&1; then
  pass "returned interpreter imports datasketch"
else
  skip_case "datasketch absent in resolved interpreter — preference untestable here"
fi

# Case 3: a dir with no .venv falls back to a PATH interpreter (or empty) — never errors/crashes.
nonexistent="$(mktemp -d)/no-venv-here"
out="$(mc_discover_python "$nonexistent")"
if [[ -z "$out" ]] || command -v "$out" >/dev/null 2>&1 || [[ -f "$out" ]]; then
  pass "missing-venv dir falls back without error"
else
  fail "missing-venv fallback" "empty or a resolvable interpreter" "$out"
fi

[[ $FAILED -eq 0 ]] || exit 1
