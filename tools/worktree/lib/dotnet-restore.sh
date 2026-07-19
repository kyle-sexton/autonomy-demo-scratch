# shellcheck shell=bash
# dotnet restore with project.assets.json freshness gate.

# worktree_lib_dotnet_restore_needed — run from repo/worktree root (cwd).
worktree_lib_dotnet_restore_needed() {
  local marker newer
  marker=$(find . -maxdepth 4 -path './*/obj/project.assets.json' -print -quit 2>/dev/null)
  [[ -z "$marker" ]] && return 0
  newer=$(find . \
    \( -name node_modules -o -name .git -o -name bin -o -name obj \) -prune -o \
    \( -name '*.csproj' -o -name 'Directory.Packages.props' -o -name 'packages.lock.json' \) \
    -newer "$marker" -print 2>/dev/null | head -n1)
  [[ -n "$newer" ]] && return 0
  return 1
}

# worktree_lib_dotnet_restore <mode: always|if-stale|skip>
# Returns 0 on success or skip; 1 on failure when restore attempted.
worktree_lib_dotnet_restore() {
  local mode="${1:-if-stale}"

  [[ "$mode" == "skip" ]] && return 0
  compgen -G "./*.slnx" >/dev/null 2>&1 || return 0
  command -v dotnet >/dev/null 2>&1 || return 1

  if [[ "$mode" == "if-stale" ]]; then
    worktree_lib_dotnet_restore_needed || return 0
  fi

  dotnet restore --verbosity quiet >/dev/null 2>&1
}
