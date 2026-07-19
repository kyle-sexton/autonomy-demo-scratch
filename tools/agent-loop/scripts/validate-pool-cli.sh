#!/usr/bin/env bash
# Headless CLI smoke for agent-loop pool images — no credentials required.
# Verifies binaries exist and print --help/--version. Skip pools whose image is not built.

set -euo pipefail

run_probe() {
  local label="$1" image="$2" command="$3"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "SKIP $label — image $image not built"
    return 0
  fi
  echo "== $label ($image) =="
  docker run --rm --entrypoint "$command" "$image" --version
  docker run --rm --entrypoint "$command" "$image" --help | head -20
  echo ""
}

run_probe "cursor-default" "agent-loop-cursor:thin" "cursor-agent"
run_probe "claude-default" "agent-loop-claude:thin" "claude"
run_probe "codex-default" "agent-loop-codex:thin" "codex"
run_probe "grok-default" "agent-loop-grok:thin" "grok"

echo "Done. Full adapter defaults: headless-cli-authority.md"
