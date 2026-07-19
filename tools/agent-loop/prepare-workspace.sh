#!/usr/bin/env bash
# Prepare or summarize an external git workspace for agent-loop runs.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  prepare-workspace.sh create --repo <git-root> --branch <name> --path <worktree-path> [--print-path]
  prepare-workspace.sh summary --workspace <path> [--run-log <orchestrator.log>]

create  — add a git worktree; print export hint on stderr (or path-only on stdout with --print-path).
summary — append git status + latest commit one-liner (optional orchestrator.log tee).

Recommended path capture (avoids eval + hook stdout pollution):

  export AGENT_LOOP_WORKSPACE="$(bash prepare-workspace.sh create ... --print-path)"
EOF
}

require_git() {
  if ! command -v git >/dev/null 2>&1; then
    echo "error: git not found on PATH" >&2
    exit 1
  fi
}

cmd_create() {
  local repo_root="" branch="" worktree_path="" print_path=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        repo_root="${2:-}"
        shift 2
        ;;
      --branch)
        branch="${2:-}"
        shift 2
        ;;
      --path)
        worktree_path="${2:-}"
        shift 2
        ;;
      --print-path)
        print_path=true
        shift
        ;;
      *)
        echo "error: unknown create arg: $1" >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "$repo_root" || -z "$branch" || -z "$worktree_path" ]]; then
    echo "error: create requires --repo, --branch, and --path" >&2
    exit 2
  fi

  require_git
  local script_dir medley_root create_sh setup_sh created_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  medley_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  create_sh="$medley_root/tools/worktree/create-worktree.sh"
  setup_sh="$medley_root/tools/worktree/setup-worktree.sh"

  # Skip lefthook post-checkout noise on stdout — breaks `eval "$(…)"` and path capture.
  created_path=$(LEFTHOOK=0 bash "$create_sh" \
    --cwd "$repo_root" \
    --branch "$branch" \
    --worktree-path "$worktree_path" \
    --skip-copy \
    --print-path)

  if [[ -f "$setup_sh" ]]; then
    if ! bash "$setup_sh" \
      --pipeline agent-loop-post-create \
      --main-root "$repo_root" \
      --worktree-root "$worktree_path" >&2; then
      echo "warning: agent-loop-post-create setup reported issues (non-fatal)" >&2
    fi
  fi

  if [[ "$print_path" == true ]]; then
    printf '%s\n' "$created_path"
  else
    printf 'hint: export AGENT_LOOP_WORKSPACE=%q\n' "$worktree_path" >&2
    printf 'export AGENT_LOOP_WORKSPACE=%q\n' "$worktree_path"
  fi
}

cmd_summary() {
  local workspace="" run_log=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace)
        workspace="${2:-}"
        shift 2
        ;;
      --run-log)
        run_log="${2:-}"
        shift 2
        ;;
      *)
        echo "error: unknown summary arg: $1" >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    echo "error: summary requires --workspace" >&2
    exit 2
  fi

  require_git
  {
    echo "=== workspace summary ==="
    git -C "$workspace" status -sb
    git -C "$workspace" log -1 --oneline
    echo ""
  } | if [[ -n "$run_log" ]]; then tee -a "$run_log"; else cat; fi
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    create)
      cmd_create "$@"
      ;;
    summary)
      cmd_summary "$@"
      ;;
    -h | --help | help | "")
      usage
      ;;
    *)
      echo "error: unknown command: $command" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
