#!/usr/bin/env bash
# Operator readiness rollup for one agent-loop pool — no spend unless --tier0.
# Usage: bash scripts/preflight-pool.sh --pool <pool-id> [--tier0] [workspace-root]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

usage() {
  cat <<'EOF'
Usage: preflight-pool.sh --pool <pool-id> [--tier0] [workspace-root]

Operator readiness rollup for one agent-loop pool — no spend unless --tier0.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

cd "$AGENT_LOOP_ROOT"
npm run build --silent
exec node build/preflight-pool.js "$@"
