#!/usr/bin/env bash
# Operator-only: compare permission modes for unattended tier-0 write.
# Requires credentialed setup (see operator/test-ladder-claude.md).
#
# Usage: bash scripts/pool-gates/claude-permission-probe.sh [workspace-root]
# Exit: 0 when every probed mode passes; 1 on first failure.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

usage() {
  cat <<'EOF'
Usage: claude-permission-probe.sh [workspace-root]

Operator-only: compare permission modes for unattended tier-0 write.
Requires credentialed setup (see operator/test-ladder-claude.md).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

WORKSPACE="${1:-$(cd "$AGENT_LOOP_ROOT/../.." && pwd)}"

cd "$AGENT_LOOP_ROOT"
npm run build >/dev/null

MODES=(dontAsk bypassPermissions auto)
failed=0

for mode in "${MODES[@]}"; do
  printf '=== AGENT_LOOP_CLAUDE_PERMISSION_PROBE=%s ===\n' "$mode"
  if ! AGENT_LOOP_CLAUDE_PERMISSION_PROBE="$mode" \
    node build/verify-claude-headless-writes.js "$WORKSPACE"; then
    printf 'FAIL: permission mode %s\n' "$mode" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

printf 'claude-permission-probe: PASS (modes: %s)\n' "${MODES[*]}"
