#!/usr/bin/env bash
# Tests for sync-cursor-catalog.sh (fixture mode, no network).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

UNIT="$REPO_ROOT/tools/model-routing"
export MODEL_ROUTING_FIXTURE_DIR="$UNIT/fixtures"
export MODEL_ROUTING_CATALOG_TTL_HOURS=0

TMP="$(mktemp -d)"
CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP" "$CACHE_DIR"' EXIT

cp "$UNIT/fixtures/pricing-snippet.md" "$TMP/pricing-snippet.md"
export MODEL_ROUTING_FIXTURE_DIR="$TMP"
export MODEL_ROUTING_CACHE_DIR="$CACHE_DIR"

OUT="$(bash "$UNIT/sync-cursor-catalog.sh" --dry-run)"
assert_contains "dry-run emits fetchedAt" "$OUT" "fetchedAt"

bash "$UNIT/sync-cursor-catalog.sh" --force
assert_eq "catalog file created" "0" "$([[ -f $CACHE_DIR/cursor-catalog.json ]] && echo 0 || echo 1)"

[[ $FAILED -eq 0 ]] || exit 1
