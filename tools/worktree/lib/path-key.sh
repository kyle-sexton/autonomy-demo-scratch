# shellcheck shell=bash
# Path identity helpers for cross-worktree boundary checks.

worktree_lib_normalize_scan_path() {
  local p="${1//\\//}" native=""
  if [[ -d "$p" ]]; then
    native=$(cd "$p" && pwd -W 2>/dev/null | tr -d '\r') || true
    [[ -n "$native" ]] && {
      printf '%s' "${native//\\//}"
      return 0
    }
  fi
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

worktree_lib_existing_ancestor() {
  local dir parent
  dir="$1"
  while [[ -n "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    if [[ -d "$dir" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    parent=$(dirname "$dir")
    [[ "$parent" == "$dir" ]] && return 1
    dir="$parent"
  done
  return 1
}

worktree_lib_resolve_git_common_dir() {
  local hint="$1" raw
  raw=$(git -C "$hint" rev-parse --git-common-dir 2>/dev/null | tr -d '\r')
  [[ -z "$raw" ]] && return 1
  if [[ "$raw" =~ ^([a-zA-Z]:)?/ ]]; then
    printf '%s' "$raw"
  else
    printf '%s/%s' "$hint" "$raw"
  fi
}

worktree_lib_path_key() {
  local p="$1"
  stat -c '%d:%i' "$p" 2>/dev/null && return 0
  stat -f '%d:%i' "$p" 2>/dev/null
}

# worktree_lib_check_cross_worktree_write <file_path> <session_cwd>
# Exit 2 = block (file lives in a sibling worktree of the same repo); 0 = allow,
# including any resolution failure (fail-open).
worktree_lib_check_cross_worktree_write() {
  local file_path="${1//\\//}" cwd="${2//\\//}"
  local file_dir file_git cwd_git file_git_key cwd_git_key file_wt cwd_wt file_wt_key cwd_wt_key

  file_dir=$(worktree_lib_existing_ancestor "$(dirname "$file_path")") || return 0
  file_git=$(worktree_lib_resolve_git_common_dir "$file_dir") || return 0
  cwd_git=$(worktree_lib_resolve_git_common_dir "$cwd") || return 0

  file_git_key=$(worktree_lib_path_key "$file_git")
  cwd_git_key=$(worktree_lib_path_key "$cwd_git")
  [[ -n "$file_git_key" && -n "$cwd_git_key" ]] || return 0
  [[ "$file_git_key" == "$cwd_git_key" ]] || return 0

  file_wt=$(git -C "$file_dir" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  cwd_wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  [[ -n "$file_wt" && -n "$cwd_wt" ]] || return 0
  file_wt_key=$(worktree_lib_path_key "$file_wt")
  cwd_wt_key=$(worktree_lib_path_key "$cwd_wt")
  [[ -n "$file_wt_key" && -n "$cwd_wt_key" ]] || return 0
  [[ "$file_wt_key" != "$cwd_wt_key" ]] || return 0

  return 2
}
