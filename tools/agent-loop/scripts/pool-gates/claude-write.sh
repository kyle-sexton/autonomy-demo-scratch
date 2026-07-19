#!/usr/bin/env bash
# Tier-0: claude-default headless workspace write.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_LOOP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${AGENT_LOOP_ROOT}/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: claude-write.sh [workspace-root]

Tier-0: claude-default headless workspace write.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

WORKSPACE="${1:-$REPO_ROOT}"

cd "$AGENT_LOOP_ROOT"
npm run build --silent
node build/verify-claude-headless-writes.js "$WORKSPACE"
