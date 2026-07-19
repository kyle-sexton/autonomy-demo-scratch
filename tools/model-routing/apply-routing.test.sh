#!/usr/bin/env bash
# Tests for apply-routing.sh (cursor + codex surfaces)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

UNIT="$REPO_ROOT/tools/model-routing"
TMP_SLICE="$UNIT/fixtures/.test-slice-$$"
CODEX_SLICE="$UNIT/fixtures/.test-codex-$$"
CACHE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_SLICE" "$CODEX_SLICE" "$CACHE_DIR"
}
trap cleanup EXIT

export MODEL_ROUTING_CACHE_DIR="$CACHE_DIR"

mkdir -p "$TMP_SLICE" "$CODEX_SLICE"

cat >"$CODEX_SLICE/routing.json" <<'EOF'
{
  "_schema_version": "1",
  "complexityTier": "standard",
  "phases": [{
    "phase": 1,
    "catalogModelId": "gpt-5-3-codex",
    "variant": "",
    "roleHint": "implement-default",
    "catalogNamespace": "codex"
  }]
}
EOF

cp "$UNIT/fixtures/routing-manifest-sample.json" "$TMP_SLICE/routing.json"
cp "$UNIT/fixtures/catalog-minimal.json" "$CACHE_DIR/cursor-catalog.json"
cp "$UNIT/fixtures/catalog-codex-minimal.json" "$CACHE_DIR/codex-catalog.json"

OUT="$(bash "$UNIT/apply-routing.sh" \
  --slice "tools/model-routing/fixtures/.test-slice-$$" \
  --phase 1 \
  --surface agent-loop-cursor \
  --dry-run)"
assert_contains "cursor dry-run has model" "$OUT" "composer-2.5-fast"

CODEX_OUT="$(bash "$UNIT/apply-routing.sh" \
  --slice "tools/model-routing/fixtures/.test-codex-$$" \
  --phase 1 \
  --surface agent-loop-codex \
  --dry-run)"
assert_contains "codex dry-run has model" "$CODEX_OUT" "gpt-5.3-codex"

[[ $FAILED -eq 0 ]] || exit 1
