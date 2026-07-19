# shellcheck shell=bash
# Read-only orphan worktree directory scan.
# shellcheck source=path-key.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path-key.sh"

# worktree_lib_porcelain_lists_path <porcelain_blob> <absolute_dir>
worktree_lib_porcelain_lists_path() {
  local list="$1" dir="$2" target line wt norm_line
  target=$(worktree_lib_normalize_scan_path "$dir")
  while IFS= read -r line; do
    [[ "$line" == worktree\ * ]] || continue
    wt="${line#worktree }"
    wt="${wt//$'\r'/}"
    norm_line=$(worktree_lib_normalize_scan_path "$wt")
    [[ "$norm_line" == "$target" ]] && return 0
  done <<<"$list"
  return 1
}

# worktree_lib_count_orphan_worktrees <main_root> <common_dir> <is_bare_hub>
# Prints orphan count to stdout.
worktree_lib_count_orphan_worktrees() {
  local main_root="${1:-}" common_dir="${2:-}" is_bare_hub="${3:-false}"
  local orphan_count=0 git_wt_list hub_root dir dir_name worktree_dir

  git_wt_list=$(git -C "$main_root" worktree list --porcelain 2>/dev/null)
  git_wt_list="${git_wt_list//$'\r'/}"

  if [[ "$is_bare_hub" == "true" ]]; then
    hub_root="${common_dir%/.bare}"
    hub_root="${hub_root%.bare}"
    for dir in "$hub_root"/*/; do
      [[ -d "$dir" ]] || continue
      dir="${dir%/}"
      dir_name=$(basename "$dir")
      [[ "$dir_name" == ".bare" ]] && continue
      if ! worktree_lib_porcelain_lists_path "$git_wt_list" "$dir"; then
        orphan_count=$((orphan_count + 1))
      fi
    done
  fi

  for worktree_dir in "$main_root/.claude/worktrees" "$main_root/.worktrees"; do
    [[ -d "$worktree_dir" ]] || continue
    for dir in "$worktree_dir"/*/; do
      [[ -d "$dir" ]] || continue
      dir="${dir%/}"
      if ! worktree_lib_porcelain_lists_path "$git_wt_list" "$dir"; then
        orphan_count=$((orphan_count + 1))
      fi
    done
  done

  printf '%s' "$orphan_count"
}
