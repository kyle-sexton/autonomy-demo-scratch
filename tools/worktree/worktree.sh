#!/usr/bin/env bash
# Worktree operator dispatcher — setup, create, list-orphans.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: worktree.sh <subcommand> [args...]

Subcommands:
  setup     Run setup-worktree.sh (--pipeline required)
  create    Run create-worktree.sh (--name and --cwd required)
  status    Emit Tier-0 worktree inventory facts (status.sh)
  list-orphans  Report orphan worktree directory count for current repo

Examples:
  bash tools/worktree/worktree.sh setup --pipeline cursor
  bash tools/worktree/worktree.sh create --name feat/foo --cwd .
EOF
}

subcommand="${1:-}"
case "$subcommand" in
  --help | -h | '')
    usage
    exit 0
    ;;
  setup)
    shift
    exec bash "$SCRIPT_DIR/setup-worktree.sh" "$@"
    ;;
  create)
    shift
    exec bash "$SCRIPT_DIR/create-worktree.sh" "$@"
    ;;
  status)
    shift
    exec bash "$SCRIPT_DIR/status.sh" "$@"
    ;;
  list-orphans)
    shift
    # shellcheck source=lib/scan-orphan-worktrees.sh
    source "$SCRIPT_DIR/lib/scan-orphan-worktrees.sh"
    # shellcheck source=lib/resolve-layout.sh
    source "$SCRIPT_DIR/lib/resolve-layout.sh"
    cwd=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --cwd)
          cwd="${2:-}"
          shift 2
          ;;
        --*)
          shift
          ;;
        *)
          [[ -z "$cwd" ]] && cwd="$1"
          shift
          ;;
      esac
    done
    cwd="${cwd:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')}"
    mapfile -t _layout < <(worktree_lib_parse_main_root_from_porcelain "$cwd")
    main_root="${_layout[0]:-$cwd}"
    is_bare=false
    [[ "${_layout[1]:-false}" == true ]] && is_bare=true
    common_dir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null | tr -d '\r')
    COUNT=$(worktree_lib_count_orphan_worktrees "$main_root" "$common_dir" "$is_bare")
    printf '%s orphan worktree dir(s)\n' "$COUNT"
    ;;
  *)
    printf 'ERROR: unknown subcommand: %s\n' "$subcommand" >&2
    usage >&2
    exit 2
    ;;
esac
