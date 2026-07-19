#!/usr/bin/env bash
# Cross-worktree Write/Edit boundary check — SSOT for worktree-boundary hook.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/path-key.sh
source "$SCRIPT_DIR/lib/path-key.sh"

usage() {
  cat <<'EOF'
Usage: enforce-boundary.sh --file-path <path> --cwd <session-cwd> [--emit-diagnostic]

Exit 0 = allow (including resolution fail-open).
Exit 2 = block cross-worktree write (stderr diagnostic when --emit-diagnostic).
EOF
}

emit_block_diagnostic() {
  local file_path="$1" cwd="$2"
  local file_dir file_wt cwd_wt cwd_git
  file_dir=$(dirname "$file_path")
  file_dir=$(worktree_lib_existing_ancestor "$file_dir") || return 0
  file_wt=$(git -C "$file_dir" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  cwd_wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  cwd_git=$(worktree_lib_resolve_git_common_dir "$cwd") || return 0
  file_wt="${file_wt//\\//}"
  cwd_wt="${cwd_wt//\\//}"
  cwd_git="${cwd_git//\\//}"

  cat >&2 <<EOF
Cross-worktree write BLOCKED — same repo, different working tree.

  Session CWD worktree: $cwd_wt
  Target file worktree: $file_wt
  Shared git-common-dir: $cwd_git
  Attempted file_path:  $file_path

This write would land on a different branch than the one checked out in the
active session. Likely cause: an absolute file_path was assembled with the
wrong worktree prefix.

Resolution paths:
  1. Use a worktree-relative path (most common fix)
  2. Switch sessions to the intended worktree: claude -w <name> or cd <target>
  3. If you genuinely need this cross-tree write, set
     HOOK_WORKTREE_BOUNDARY_ENABLED=false in .claude/settings.local.json env
     for the duration, then flip back

This hook only fires for SAME-REPO cross-worktree writes. Writes to ~/.claude,
~/repos/other-repo, \$TMPDIR, or any path outside this repo's git tree are
unaffected.
EOF
}

main() {
  local file_path="" cwd="" emit_diagnostic=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file-path)
        file_path="${2:-}"
        shift 2
        ;;
      --cwd)
        cwd="${2:-}"
        shift 2
        ;;
      --emit-diagnostic)
        emit_diagnostic=true
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  done

  [[ -n "$file_path" && -n "$cwd" ]] || exit 0

  if worktree_lib_check_cross_worktree_write "$file_path" "$cwd"; then
    exit 0
  fi
  if [[ "$emit_diagnostic" == true ]]; then
    emit_block_diagnostic "$file_path" "$cwd" || true
  fi
  exit 2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
