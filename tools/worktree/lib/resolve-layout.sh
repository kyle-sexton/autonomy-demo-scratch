# shellcheck shell=bash
# Worktree path layout detection — standard clone vs bare-clone hub.
# shellcheck source=path-key.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path-key.sh"

# worktree_lib_resolve_worktree_path <cwd> <safe_name>
# Sets: WORKTREE_PATH, GIT_CONTEXT, HUB_ROOT, REPO_ROOT (when applicable)
# Returns 1 on failure.
worktree_lib_resolve_worktree_path() {
  local cwd="${1:-}" safe_name="${2:-}"
  local is_bare common_dir abs_git_dir

  export WORKTREE_PATH=""
  export GIT_CONTEXT=""
  export HUB_ROOT=""
  export REPO_ROOT=""

  cwd="${cwd//\\//}"
  # Single git spawn for all layout metadata. Process LAUNCH is the dominant cost
  # on Windows (Tier-0: 2-8s/spawn under load), so collapse 3 rev-parse calls into
  # 1 — measured ~7x faster (17.5s->2.6s) for the 4-flag cluster. --is-bare-repository
  # / --git-common-dir / --absolute-git-dir are valid in bare AND non-bare repos;
  # --show-toplevel is fetched separately on the non-bare path only (it errors in a
  # bare repo and would abort a combined call). mapfile + ${//} are builtins (no fork).
  local _rp
  mapfile -t _rp < <(git -C "$cwd" rev-parse --is-bare-repository --git-common-dir --absolute-git-dir 2>/dev/null)
  is_bare="${_rp[0]//$'\r'/}"
  common_dir="${_rp[1]//$'\r'/}"
  abs_git_dir="${_rp[2]//$'\r'/}"
  common_dir="${common_dir//\\//}"

  if [[ "$is_bare" == "true" ]]; then
    abs_git_dir="${abs_git_dir//\\//}"
    HUB_ROOT="${abs_git_dir%/.bare}"
    HUB_ROOT="${HUB_ROOT%.bare}"
    export HUB_ROOT WORKTREE_PATH="$HUB_ROOT/$safe_name" GIT_CONTEXT="$cwd"
  elif [[ "$common_dir" == */.bare || "$common_dir" == *.bare ]]; then
    HUB_ROOT="${common_dir%/.bare}"
    HUB_ROOT="${HUB_ROOT%.bare}"
    export HUB_ROOT WORKTREE_PATH="$HUB_ROOT/$safe_name" GIT_CONTEXT="$cwd"
  else
    REPO_ROOT=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
    REPO_ROOT="${REPO_ROOT//\\//}"
    [[ -n "$REPO_ROOT" ]] || return 1
    export WORKTREE_PATH="$REPO_ROOT/.worktrees/$safe_name"
    export GIT_CONTEXT="$REPO_ROOT"
    export REPO_ROOT
  fi
  return 0
}

# worktree_lib_resolve_include_source <cwd> <worktree_path> <hub_root_or_empty> <repo_root_or_empty>
worktree_lib_resolve_include_source() {
  local cwd="${1:-}" worktree_path="${2:-}" hub_root="${3:-}" repo_root="${4:-}"
  local include_source wt_line

  if [[ -n "$hub_root" ]]; then
    include_source=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
    include_source="${include_source//\\//}"
    if [[ -z "$include_source" ]]; then
      while IFS= read -r wt_line; do
        wt_line="${wt_line#worktree }"
        [[ "$(worktree_lib_normalize_scan_path "$wt_line")" == "$(worktree_lib_normalize_scan_path "$worktree_path")" ]] && continue
        if [[ -f "$wt_line/.worktreeinclude" ]]; then
          include_source="$wt_line"
          break
        fi
      done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | grep '^worktree ' | tr -d '\r')
    fi
    printf '%s' "${include_source:-}"
  else
    printf '%s' "${repo_root:-}"
  fi
}

# worktree_lib_worktree_registered <git_context> <worktree_path>
worktree_lib_worktree_registered() {
  local git_context="${1:-}" worktree_path="${2:-}"
  local list target line wt norm_line
  target=$(worktree_lib_normalize_scan_path "$worktree_path")
  list=$(git -C "$git_context" worktree list --porcelain 2>/dev/null | tr -d '\r')
  while IFS= read -r line; do
    [[ "$line" == worktree\ * ]] || continue
    wt="${line#worktree }"
    norm_line=$(worktree_lib_normalize_scan_path "$wt")
    [[ "$norm_line" == "$target" ]] && return 0
  done <<<"$list"
  return 1
}

# worktree_lib_parse_main_root_from_porcelain <cwd>
# stdout line 1: main_root; line 2: bare_hub (true|false)
worktree_lib_parse_main_root_from_porcelain() {
  local cwd="${1:-}" wt_candidate="" main_root="" bare_hub=false wt_line
  while IFS= read -r wt_line; do
    wt_line="${wt_line//$'\r'/}"
    case "$wt_line" in
      "worktree "*) wt_candidate="${wt_line#worktree }" ;;
      bare)
        wt_candidate=""
        bare_hub=true
        ;;
      "") [[ -n "$wt_candidate" ]] && {
        main_root="$wt_candidate"
        break
      } ;;
      *) ;;
    esac
  done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | tr -d '\r')
  [[ -z "$main_root" && -n "$wt_candidate" ]] && main_root="$wt_candidate"
  main_root="${main_root//\\//}"
  printf '%s\n%s\n' "$main_root" "$bare_hub"
}

# worktree_lib_detect_claude_session <cwd>
# stdout line 1: main_root; line 2: bare_hub; line 3: is_worktree; line 4: worktree_root
worktree_lib_detect_claude_session() {
  local cwd="${1:-}" main_root="" bare_hub=false is_worktree=false worktree_root=""
  local common_dir is_bare_hub toplevel main_wt_line main_wt _layout

  cwd="${cwd//\\//}"
  mapfile -t _layout < <(worktree_lib_parse_main_root_from_porcelain "$cwd")
  main_root="${_layout[0]:-}"
  bare_hub="${_layout[1]:-false}"
  [[ -n "$main_root" ]] || return 1

  worktree_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  worktree_root="${worktree_root//\\//}"

  common_dir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null | tr -d '\r')
  common_dir="${common_dir//\\//}"
  is_bare_hub=false
  if [[ "$common_dir" == */.bare || "$common_dir" == *.bare ]]; then
    is_bare_hub=true
  fi

  case "$cwd" in
    */.claude/worktrees/* | */.worktrees/*) is_worktree=true ;;
  esac

  if [[ "$is_bare_hub" == true && "$is_worktree" == false ]]; then
    toplevel="$worktree_root"
    read -r main_wt_line < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | tr -d '\r' | head -1)
    main_wt="${main_wt_line#worktree }"
    main_wt="${main_wt//$'\r'/}"
    main_wt="${main_wt//\\//}"
    if [[ -n "$toplevel" && -n "$main_wt" && "$toplevel" != "$main_wt" ]]; then
      is_worktree=true
    fi
  fi

  printf '%s\n%s\n%s\n%s\n' "$main_root" "$bare_hub" "$is_worktree" "${worktree_root:-}"
}
