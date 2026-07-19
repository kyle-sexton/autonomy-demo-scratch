# shellcheck shell=bash
# Copy gitignored paths listed in .worktreeinclude from source root to worktree root.

# worktree_lib_copy_worktreeinclude <include_source_root> <worktree_root> [log_prefix]
# Returns 0; per-file failures log warnings and continue.
worktree_lib_copy_worktreeinclude() {
  local include_source="${1:-}" worktree_root="${2:-}" log_prefix="${3:-worktree-copy}"
  local include_file line src dst

  if [[ -z "$include_source" || -z "$worktree_root" ]]; then
    return 0
  fi

  include_file="$include_source/.worktreeinclude"
  [[ -f "$include_file" ]] || return 0

  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    src="$include_source/$line"
    dst="$worktree_root/$line"
    if [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$dst")" 2>/dev/null
      if cp "$src" "$dst" 2>/dev/null; then
        printf '%s: copied %s\n' "$log_prefix" "$line" >&2
      else
        printf '%s: WARN copy failed for %s\n' "$log_prefix" "$line" >&2
      fi
    fi
  done <"$include_file"
}
