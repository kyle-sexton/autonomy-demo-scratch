#!/usr/bin/env bash
# Tests for sync-codex-catalog.sh (registry-only, no network).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

UNIT="$REPO_ROOT/tools/model-routing"

OUT="$(bash "$UNIT/sync-codex-catalog.sh" --dry-run)"
assert_contains "codex dry-run has gpt-5.3-codex" "$OUT" "gpt-5.3-codex"

bash "$UNIT/sync-codex-catalog.sh" --force
assert_eq "codex catalog file created" "0" "$([[ -f $UNIT/cache/codex-catalog.json ]] && echo 0 || echo 1)"

[[ $FAILED -eq 0 ]] || exit 1
