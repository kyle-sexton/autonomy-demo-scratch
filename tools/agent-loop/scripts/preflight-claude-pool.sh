#!/usr/bin/env bash
# Deprecated alias — use scripts/preflight-pool.sh --pool claude-default
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preflight-pool.sh" --help
fi
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preflight-pool.sh" --pool claude-default "$@"
