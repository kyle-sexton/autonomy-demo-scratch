#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

out="$(bash "$SCRIPT_DIR/open-pr-count.sh" --help 2>/dev/null)"
assert_contains "open-pr-count help" "$out" "open-pr-count.sh"

out="$(bash "$SCRIPT_DIR/last-tidy-merge.sh" --help 2>/dev/null)"
assert_contains "last-tidy-merge help" "$out" "last-tidy-merge.sh"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: tidy tools tests passed"
