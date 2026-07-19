#!/usr/bin/env bash
# Codex Cloud maintenance entrypoint for cached container resumes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MEDIA_TOOLS_REQUIRED=false bash "$ROOT/tools/bootstrap.sh" --quiet
