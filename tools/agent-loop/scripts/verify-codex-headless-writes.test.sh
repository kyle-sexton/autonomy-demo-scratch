#!/usr/bin/env bash
# Structural wiring for Codex tier-0 gate — no ~/.codex/auth.json spend.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$AGENT_LOOP_ROOT/../.." && pwd)

# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

cd "$AGENT_LOOP_ROOT"
[[ -x node_modules/.bin/tsc ]] || skip_suite "agent-loop deps absent — run: cd tools/agent-loop && npm ci"
npm run build >/dev/null

assert_file_exists "verify-codex-headless-writes.js built" \
  "$AGENT_LOOP_ROOT/build/verify-codex-headless-writes.js"

node --input-type=module -e "
import { resolvePoolSessionBindMounts } from './build/pool-session-bind-mounts/resolve.js';
import { CODEX_AGENT_POOL } from './build/agent-pool.js';

if (CODEX_AGENT_POOL.inContainerHooks !== 'none') {
  console.error('expected inContainerHooks none, got', CODEX_AGENT_POOL.inContainerHooks);
  process.exit(1);
}

const mounts = resolvePoolSessionBindMounts(CODEX_AGENT_POOL, {
  workspaceRoot: process.argv[1],
  agentLoopProjectRoot: process.argv[2],
  runId: 'tier0-test',
});
if (mounts.length !== 0) {
  console.error('expected 0 bind mounts for codex pool, got', mounts.length);
  process.exit(1);
}
" "$REPO_ROOT" "$AGENT_LOOP_ROOT"

pass "codex tier-0 wiring resolves with inContainerHooks=none and empty session mounts"
