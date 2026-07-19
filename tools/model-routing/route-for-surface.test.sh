#!/usr/bin/env bash
# Tests for route-for-surface.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

UNIT="$REPO_ROOT/tools/model-routing"
TMP_SLICE="$REPO_ROOT/tools/model-routing/fixtures/.route-slice"
CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_SLICE" "$CACHE_DIR"' EXIT
mkdir -p "$TMP_SLICE"

cat >"$TMP_SLICE/PLAN.md" <<'EOF'
# Plan

**LOW.** blast radius
EOF

export MODEL_ROUTING_FIXTURE_DIR="$UNIT/fixtures"
export MODEL_ROUTING_CACHE_DIR="$CACHE_DIR"
cp "$UNIT/fixtures/catalog-minimal.json" "$CACHE_DIR/cursor-catalog.json"

bash "$UNIT/route-for-surface.sh" \
  --slice tools/model-routing/fixtures/.route-slice \
  --phase 1 \
  --surface agent-loop-cursor \
  --dry-run >/dev/null

assert_eq "manifest created" "0" "$([[ -f $TMP_SLICE/routing.json ]] && echo 0 || echo 1)"

rm -rf "$TMP_SLICE"

[[ $FAILED -eq 0 ]] || exit 1
