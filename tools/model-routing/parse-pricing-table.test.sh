#!/usr/bin/env bash
# Tests for parse-pricing-table.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

UNIT="$REPO_ROOT/tools/model-routing"
# shellcheck source=lib/parse-pricing-table.sh
source "$UNIT/lib/parse-pricing-table.sh"

OUT="$(parse_pricing_model_ids <"$UNIT/fixtures/pricing-snippet.md" | tr '\n' ' ')"
assert_contains "parses composer row" "$OUT" "composer"

[[ $FAILED -eq 0 ]] || exit 1
