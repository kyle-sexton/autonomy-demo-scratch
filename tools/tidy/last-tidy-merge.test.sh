#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

LAST="$SCRIPT_DIR/last-tidy-merge.sh"

assert_exit "--help exits 0" 0 "$(
  bash "$LAST" --help >/dev/null 2>&1
  echo $?
)"

out="$(bash "$LAST" docs 2>/dev/null)"
assert_contains "Lane label" "$out" "Lane: docs"
assert_contains "Anchor source label" "$out" "Anchor source:"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: last-tidy-merge.sh tests passed"
