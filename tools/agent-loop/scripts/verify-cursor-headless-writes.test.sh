#!/usr/bin/env bash
# Unit-level checks for tier-0 script wiring (no CURSOR_API_KEY spend).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENT_LOOP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$AGENT_LOOP_ROOT/../.." && pwd)

# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

cd "$AGENT_LOOP_ROOT"
[[ -x node_modules/.bin/tsc ]] || skip_suite "agent-loop deps absent — run: cd tools/agent-loop && npm ci"
npm run build >/dev/null

assert_file_exists "verify-headless-writes.js built" "$AGENT_LOOP_ROOT/build/verify-headless-writes.js"

node --input-type=module -e "
import { resolvePoolSessionBindMounts } from './build/pool-session-bind-mounts/resolve.js';
import { CURSOR_AGENT_POOL } from './build/agent-pool.js';

const mounts = resolvePoolSessionBindMounts(CURSOR_AGENT_POOL, {
  workspaceRoot: process.argv[1],
  agentLoopProjectRoot: process.argv[2],
  runId: 'tier0-test',
});
if (mounts.length !== 2) {
  console.error('expected 2 suppression mounts, got', mounts.length);
  process.exit(1);
}
" "$REPO_ROOT" "$AGENT_LOOP_ROOT"

pass "cursor tier-0 suppression mounts resolve for repo workspace"
