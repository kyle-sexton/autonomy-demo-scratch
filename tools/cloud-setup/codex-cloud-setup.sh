#!/usr/bin/env bash
# Codex Cloud setup entrypoint for this repository.
# Runs in a fresh Codex Cloud container before the agent phase.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "$(id -u)" == "0" ]]; then
  bash "$ROOT/tools/cloud-setup/setup.sh"
else
  echo "WARN: not running as root; skipping system package install from tools/cloud-setup/setup.sh" >&2
fi

MEDIA_TOOLS_REQUIRED=false bash "$ROOT/tools/bootstrap.sh"
