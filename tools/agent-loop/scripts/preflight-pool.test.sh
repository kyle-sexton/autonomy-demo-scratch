#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
source "$AGENT_LOOP_ROOT/../../tests/shell/lib.sh"

assert_file_exists "preflight-pool.sh exists" "$SCRIPT_DIR/preflight-pool.sh"
help_out=$(bash "$SCRIPT_DIR/preflight-pool.sh" --help)
assert_contains "preflight-pool --help mentions Usage" "$help_out" "Usage:"

pass "preflight-pool script contract tests"
