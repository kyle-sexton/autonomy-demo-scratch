#!/usr/bin/env bash
# Tier-0: codex-default headless workspace write.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_LOOP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${AGENT_LOOP_ROOT}/../.." && pwd)"
WORKSPACE="${1:-$REPO_ROOT}"

cd "$AGENT_LOOP_ROOT"
npm run build --silent
node build/verify-codex-headless-writes.js "$WORKSPACE"
