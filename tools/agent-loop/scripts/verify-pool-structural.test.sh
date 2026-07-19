#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
source "$AGENT_LOOP_ROOT/../../tests/shell/lib.sh"

assert_file_exists "verify-pool-structural.sh exists" "$SCRIPT_DIR/verify-pool-structural.sh"
help_out=$(bash "$SCRIPT_DIR/verify-pool-structural.sh" --help)
assert_contains "verify-pool-structural --help mentions Usage" "$help_out" "Usage:"

pass "verify-pool-structural script contract tests"
