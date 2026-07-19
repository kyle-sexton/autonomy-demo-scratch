#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck disable=SC1091
source "$AGENT_LOOP_ROOT/../../tests/shell/lib.sh"

assert_file_exists "claude-permission-probe.sh exists" "$SCRIPT_DIR/claude-permission-probe.sh"
help_out=$(bash "$SCRIPT_DIR/claude-permission-probe.sh" --help)
assert_contains "claude-permission-probe --help mentions Usage" "$help_out" "Usage:"

pass "claude-permission-probe script contract tests"
