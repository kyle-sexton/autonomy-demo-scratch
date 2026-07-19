# shellcheck shell=bash
# Per-clone origin/main fetch timestamp — mirrors hook::fetch_marker_file keying for branch-awareness.sh.

worktree_lib_cache_dir() {
  if [[ -n "${LOCALAPPDATA:-}" ]]; then
    printf '%s' "${LOCALAPPDATA//\\//}/medley"
  else
    printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/medley"
  fi
}

# worktree_lib_fetch_marker_file <git-dir>
worktree_lib_fetch_marker_file() {
  local dir="${1:-}"
  local common token
  [[ -n "$dir" ]] || return 1
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | tr -d '\r')
  [[ -n "$common" ]] || common="$dir"
  token=$(printf '%s' "$common" | cksum | cut -d' ' -f1)
  printf '%s' "$(worktree_lib_cache_dir)/last-fetch-${token}.ts"
}
