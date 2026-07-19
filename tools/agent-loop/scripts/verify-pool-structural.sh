#!/usr/bin/env bash
# Run structural tier-0 wiring tests for all agent-loop pools (no credentials).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
Usage: verify-pool-structural.sh

Run structural tier-0 wiring tests for all agent-loop pools (no credentials).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

bash "$SCRIPT_DIR/verify-cursor-headless-writes.test.sh"
bash "$SCRIPT_DIR/verify-claude-headless-writes.test.sh"
bash "$SCRIPT_DIR/verify-codex-headless-writes.test.sh"
bash "$SCRIPT_DIR/verify-grok-headless-writes.test.sh"

printf 'all pool structural tests passed\n'
