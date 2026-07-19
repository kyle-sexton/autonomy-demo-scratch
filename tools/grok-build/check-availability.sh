#!/usr/bin/env bash
# Report Grok Build CLI availability for agents/operators (optional tooling).
#
# Usage: bash tools/grok-build/check-availability.sh
# stdout: single-line JSON from the native grok-availability probe

set -euo pipefail

exec node "$(dirname "${BASH_SOURCE[0]}")/grok-availability.mjs"
