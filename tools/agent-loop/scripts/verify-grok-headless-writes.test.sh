#!/usr/bin/env bash
# Structural wiring for Grok tier-0 gate — no ~/.grok/auth.json spend.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$AGENT_LOOP_ROOT/../.." && pwd)

# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

cd "$AGENT_LOOP_ROOT"
[[ -x node_modules/.bin/tsc ]] || skip_suite "agent-loop deps absent — run: cd tools/agent-loop && npm ci"
npm run build >/dev/null

assert_file_exists "verify-grok-headless-writes.js built" \
  "$AGENT_LOOP_ROOT/build/verify-grok-headless-writes.js"

node --input-type=module -e "
import { resolvePoolSessionBindMounts } from './build/pool-session-bind-mounts/resolve.js';
import { GROK_AGENT_POOL } from './build/agent-pool.js';

if (GROK_AGENT_POOL.inContainerHooks !== 'none') {
  console.error('expected inContainerHooks none, got', GROK_AGENT_POOL.inContainerHooks);
  process.exit(1);
}

const mounts = resolvePoolSessionBindMounts(GROK_AGENT_POOL, {
  workspaceRoot: process.argv[1],
  agentLoopProjectRoot: process.argv[2],
  runId: 'tier0-test',
});
if (mounts.length !== 0) {
  console.error('expected 0 bind mounts for grok pool, got', mounts.length);
  process.exit(1);
}
" "$REPO_ROOT" "$AGENT_LOOP_ROOT"

pass "grok tier-0 wiring resolves with inContainerHooks=none and empty session mounts"
