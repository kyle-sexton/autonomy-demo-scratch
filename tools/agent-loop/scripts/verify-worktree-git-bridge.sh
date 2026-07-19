#!/usr/bin/env bash
# Tier-0 gate: git status inside thin container with linked-worktree bridge.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$AGENT_LOOP_ROOT/../.." && pwd)

usage() {
  cat <<'EOF'
Usage: verify-worktree-git-bridge.sh [workspace-root]

Tier-0 acceptance for worktree git bridge on cursor-default pool.
Requires: npm run build, docker, agent-loop-cursor:thin image.

Examples:
  bash scripts/verify-worktree-git-bridge.sh
  bash scripts/verify-worktree-git-bridge.sh /path/to/worktree
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

WORKSPACE="${1:-$REPO_ROOT}"

if ! docker image inspect agent-loop-cursor:thin >/dev/null 2>&1; then
  echo "error: image agent-loop-cursor:thin not built — run: docker build -t agent-loop-cursor:thin $AGENT_LOOP_ROOT" >&2
  exit 1
fi

cd "$AGENT_LOOP_ROOT"
if [[ ! -f build/verify-worktree-git-bridge.js ]]; then
  npm run build
fi

node build/verify-worktree-git-bridge.js "$WORKSPACE"
