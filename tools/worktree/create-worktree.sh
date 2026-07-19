#!/usr/bin/env bash
# Create a git worktree with conforming branch name and .worktreeinclude copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/branch-name.sh
source "$SCRIPT_DIR/lib/branch-name.sh"
# shellcheck source=lib/copy-worktreeinclude.sh
source "$SCRIPT_DIR/lib/copy-worktreeinclude.sh"
# shellcheck source=lib/resolve-layout.sh
source "$SCRIPT_DIR/lib/resolve-layout.sh"

GIT_BIN="${GIT_BIN:-git}"

usage() {
  cat <<'EOF'
Usage: create-worktree.sh --name <name> --cwd <git-cwd> [--print-path] [--skip-copy]
       create-worktree.sh --cwd <git-cwd> --branch <branch> --worktree-path <path> [--print-path] [--skip-copy]

Creates git worktree with derived <type>/<desc> branch from --name (default mode),
or with explicit --branch + --worktree-path (agent-loop / external path mode).
Stdout: normalized worktree path (single line).

Options:
  --name <name>           Worktree name (may include type/desc slash)
  --cwd <path>            Git context directory
  --branch <branch>       Explicit branch (requires --worktree-path)
  --worktree-path <path>  Explicit worktree path (requires --branch)
  --print-path            Print path only on stdout
  --skip-copy             Skip .worktreeinclude copy (re-entry fast path)
  --help                  Show this help
EOF
}

normalize_path() {
  local p="${1//\\//}"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# Explicit mode prints the requested path verbatim; derived mode normalizes it.
emit_worktree_path() {
  local explicit="$1" worktree_path="$2"
  if [[ "$explicit" == true ]]; then
    printf '%s\n' "$worktree_path"
  else
    printf '%s\n' "$(normalize_path "$worktree_path")"
  fi
}

git_worktree_add() {
  local git_context="$1" branch_name="$2" worktree_path="$3"
  if "$GIT_BIN" -C "$git_context" show-ref --verify --quiet "refs/heads/$branch_name"; then
    "$GIT_BIN" -C "$git_context" worktree add "$worktree_path" "$branch_name" >&2
    return $?
  fi
  if "$GIT_BIN" -C "$git_context" rev-parse --verify origin/HEAD >/dev/null 2>&1; then
    if "$GIT_BIN" -C "$git_context" worktree add -b "$branch_name" "$worktree_path" origin/HEAD >&2; then
      return 0
    fi
  fi
  "$GIT_BIN" -C "$git_context" worktree add -b "$branch_name" "$worktree_path" >&2
}

main() {
  local name="" cwd="" branch="" worktree_path="" skip_copy=false explicit=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="${2:-}"
        shift 2
        ;;
      --cwd)
        cwd="${2:-}"
        shift 2
        ;;
      --branch)
        branch="${2:-}"
        shift 2
        ;;
      --worktree-path)
        worktree_path="${2:-}"
        shift 2
        ;;
      --print-path) shift ;;
      --skip-copy)
        skip_copy=true
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        printf 'create-worktree.sh: unknown arg %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  if [[ -n "$worktree_path" || -n "$branch" ]]; then
    explicit=true
    [[ -n "$worktree_path" && -n "$branch" && -n "$cwd" ]] || {
      usage >&2
      exit 2
    }
  else
    [[ -n "$name" && -n "$cwd" ]] || {
      usage >&2
      exit 2
    }
  fi

  local safe_name branch_name git_context include_source hub_root repo_root
  if [[ "$explicit" == true ]]; then
    git_context="$cwd"
    repo_root="$("$GIT_BIN" -C "$git_context" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
    hub_root=""
    branch_name="$branch"
  else
    safe_name=$(worktree_lib_sanitize_worktree_name "$name")
    if [[ -z "$safe_name" ]]; then
      printf 'create-worktree.sh: name sanitized to empty (got %q)\n' "$name" >&2
      exit 1
    fi

    worktree_lib_resolve_worktree_path "$cwd" "$safe_name" || {
      printf 'create-worktree.sh: could not resolve layout from cwd=%q\n' "$cwd" >&2
      exit 1
    }
    worktree_path="$WORKTREE_PATH"
    git_context="$GIT_CONTEXT"
    hub_root="${HUB_ROOT:-}"
    repo_root="${REPO_ROOT:-}"
    branch_name=$(worktree_lib_derive_branch_name "$name" "$safe_name")
  fi

  # Concurrent same-hub sessions (e.g. 5 tabs launched at once with the same
  # --worktree name) can race `git worktree add` on one path — all but one fail.
  # That race is tolerated, not prevented: the post-add registered re-check below
  # treats "registered after a failed add" as idempotent reuse. (No flock — it is
  # absent on Git for Windows, where it served only as a no-op.)

  if worktree_lib_worktree_registered "$git_context" "$worktree_path"; then
    printf 'create-worktree.sh: reusing existing worktree at %s\n' "$worktree_path" >&2
    emit_worktree_path "$explicit" "$worktree_path"
    exit 0
  fi

  if ! git_worktree_add "$git_context" "$branch_name" "$worktree_path"; then
    # A concurrent session may have created it between our check and add — if it
    # is now registered, that is success (idempotent reuse), not a failure.
    if worktree_lib_worktree_registered "$git_context" "$worktree_path"; then
      printf 'create-worktree.sh: reusing worktree created concurrently at %s\n' "$worktree_path" >&2
      emit_worktree_path "$explicit" "$worktree_path"
      exit 0
    fi
    printf 'create-worktree.sh: git worktree add failed for %s\n' "$worktree_path" >&2
    exit 1
  fi

  if [[ "$skip_copy" != true ]]; then
    if [[ "$explicit" == true ]]; then
      include_source="$repo_root"
    else
      include_source=$(worktree_lib_resolve_include_source "$cwd" "$worktree_path" "$hub_root" "$repo_root")
    fi
    worktree_lib_copy_worktreeinclude "$include_source" "$worktree_path" "create-worktree"
  fi

  emit_worktree_path "$explicit" "$worktree_path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
