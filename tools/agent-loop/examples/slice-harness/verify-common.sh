#!/usr/bin/env bash
# Shared helpers for {{SLUG}} phase host verification.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# shellcheck source=../../scripts/slice-verify-common.sh
source "$REPO_ROOT/tools/agent-loop/scripts/slice-verify-common.sh"

slice_verify_init "$SCRIPT_DIR" "{{SLUG}}" "{{OUT_SUBDIR}}"

# Legacy aliases for templates that reference REPO_ROOT / SLICE_ROOT / OUT_DIR directly.
export SLICE_ROOT="$SLICE_VERIFY_SLICE_ROOT"
export OUT_DIR="$SLICE_VERIFY_OUT_DIR"
