#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

out="$(bash "$SCRIPT_DIR/corpus-diff.sh" 2>/dev/null)"
assert_contains "diff base label" "$out" "Diff base:"
assert_contains "in-scope count" "$out" "In-scope count:"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: corpus-diff.sh tests passed"
