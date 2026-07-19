#!/usr/bin/env bash
# Regression tests for tools/shared/node-runtime/install-fnm.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./install-fnm.sh
source "$SCRIPT_DIR/install-fnm.sh"

# shellcheck source=../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

fail() {
  CASE_NUM=$((CASE_NUM + 1))
  printf 'FAIL: [%d] %s — %s\n' "$CASE_NUM" "$1" "$2" >&2
  FAILED=$((FAILED + 1))
}

if declare -f install_fnm >/dev/null 2>&1; then
  pass "install_fnm is defined after sourcing install-fnm.sh"
else
  fail "install_fnm should be defined" "declare -f returned non-zero"
fi

fnm_body="$(declare -f install_fnm)"
if [[ "$fnm_body" == *'fnm.vercel.app/install'* ]]; then
  pass "install_fnm downloads from fnm.vercel.app/install (upstream)"
else
  fail "install_fnm must use the upstream installer URL" "unexpected installer source"
fi

if [[ "$fnm_body" == *'--skip-shell'* ]]; then
  pass "install_fnm passes --skip-shell (no ~/.bashrc mutation)"
else
  fail "install_fnm must pass --skip-shell" "installer would mutate shell rc"
fi

[[ "$FAILED" -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
