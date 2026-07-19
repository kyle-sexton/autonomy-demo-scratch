#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

SCRIPT="$SCRIPT_DIR/find-literal-triplication.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LITERAL="This is a long repeated instructional line used for triplication detection testing only."
printf '%s\n' "$LITERAL" >"$TMP/a.md"
printf '%s\n' "$LITERAL" >"$TMP/b.md"
printf '%s\n' "$LITERAL" >"$TMP/c.md"
printf '%s\n' "$TMP/a.md" "$TMP/b.md" "$TMP/c.md" >"$TMP/paths.txt"

out="$(TRIPLICATION_THRESHOLD=3 bash "$SCRIPT" --paths-file "$TMP/paths.txt" 2>/dev/null)"
assert_contains "detects triplication" "$out" "Count: 3"
assert_contains "summary line" "$out" "Summary: hits=1"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: find-literal-triplication.sh tests passed"
