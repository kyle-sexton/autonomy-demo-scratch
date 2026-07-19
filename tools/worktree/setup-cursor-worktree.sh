#!/usr/bin/env bash
# Cursor worktree adapter — delegates to setup-worktree.sh (tools/worktree/README.md "Setup pipeline").
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  exec bash "$SCRIPT_DIR/setup-worktree.sh" --help
fi

export ROOT_WORKTREE_PATH="${ROOT_WORKTREE_PATH:-}"
exec bash "$SCRIPT_DIR/setup-worktree.sh" --pipeline cursor "$@"
