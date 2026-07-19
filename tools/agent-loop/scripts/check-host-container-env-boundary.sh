#!/usr/bin/env bash
# Read-only check: host env and git config must not carry container workspace paths.
# Sentinel list SSOT: tools/agent-loop/src/container-boundary.ts
# Full risk register: docs/agent-loop/git-container-boundary.md
set -euo pipefail

failed=0

git_for_windows_install_workspace_sentinel() {
  local exec_path git_root
  exec_path="$(git --exec-path 2>/dev/null || true)"
  exec_path="${exec_path//\\//}"
  case "$exec_path" in
    */mingw64/libexec/git-core)
      git_root="${exec_path%/mingw64/libexec/git-core}/workspace"
      printf '%s\n' "$git_root"
      ;;
  esac
}

is_sentinel() {
  local value="${1:-}" sentinel
  [[ -z "$value" ]] && return 1
  value="${value//\\//}"
  while IFS= read -r sentinel; do
    [[ -z "$sentinel" ]] && continue
    sentinel="${sentinel//\\//}"
    [[ "$value" == "$sentinel" ]] && return 0
  done < <(container_workspace_sentinels)
  return 1
}

value_contains_sentinel() {
  local value="${1:-}" sentinel
  is_sentinel "$value" && return 0
  [[ -z "$value" ]] && return 1
  value="${value//\\//}"
  while IFS= read -r sentinel; do
    [[ -z "$sentinel" ]] && continue
    sentinel="${sentinel//\\//}"
    if [[ "$value" == *"$sentinel"* ]]; then
      return 0
    fi
  done < <(container_workspace_sentinels)
  return 1
}

container_workspace_sentinels() {
  printf '%s\n' "/workspace"
  if [[ -n "${MINGW_PREFIX:-}" ]]; then
    printf '%s\n' "${MINGW_PREFIX}/workspace"
  fi
  git_for_windows_install_workspace_sentinel
}

check_var() {
  local name="$1" value="${!1:-}"
  if is_sentinel "$value"; then
    printf 'error: %s is set to container-only path %q on the host\n' "$name" "$value" >&2
    failed=1
  fi
}

check_var CLAUDE_PROJECT_DIR
check_var GIT_WORK_TREE

if git rev-parse --git-dir >/dev/null 2>&1; then
  core_worktree="$(git config --get core.worktree 2>/dev/null || true)"
  if is_sentinel "$core_worktree"; then
    printf 'error: git config core.worktree is container-only path %q\n' "$core_worktree" >&2
    printf 'hint: git config --unset core.worktree  (from any hub worktree)\n' >&2
    failed=1
  fi

  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      filemode="$(git config --local --get core.filemode 2>/dev/null | tr -d '\r')"
      if [[ "$filemode" != "false" ]]; then
        printf 'error: git config core.filemode is %q on Windows (expected false)\n' "${filemode:-<unset>}" >&2
        printf 'hint: git config --local core.filemode false  (or bash tools/bootstrap.sh)\n' >&2
        printf 'hint: Linux container git on a bind mount can flip this — agent-loop repairs on start\n' >&2
        failed=1
      fi
      ;;
  esac

  autocrlf="$(git config --local --get core.autocrlf 2>/dev/null | tr -d '\r' || true)"
  if [[ "$autocrlf" == "true" ]]; then
    printf 'error: git config core.autocrlf is true (expected false)\n' >&2
    printf 'hint: git config --local core.autocrlf false\n' >&2
    failed=1
  fi

  while IFS= read -r safe_dir; do
    [[ -z "$safe_dir" ]] && continue
    if [[ "$safe_dir" == "*" ]]; then
      printf 'error: git config safe.directory includes * (weakens ownership checks)\n' >&2
      printf 'hint: git config --local --unset-all safe.directory *\n' >&2
      failed=1
    fi
  done < <(git config --local --get-all safe.directory 2>/dev/null || true)

  hooks_path="$(git config --local --get core.hooksPath 2>/dev/null || true)"
  if value_contains_sentinel "$hooks_path"; then
    printf 'error: git config core.hooksPath contains container path %q\n' "$hooks_path" >&2
    failed=1
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      core.worktree | core.filemode | core.autocrlf | safe.directory | core.hooksPath) continue ;;
    esac
    if value_contains_sentinel "$value"; then
      printf 'error: git config %s contains container path %q\n' "$key" "$value" >&2
      failed=1
    fi
  done < <(git config --local --list 2>/dev/null || true)
fi

if [[ "$failed" -ne 0 ]]; then
  printf 'hint: see docs/agent-loop/git-container-boundary.md\n' >&2
  exit 1
fi

printf 'ok: no container workspace paths in host environment or git config\n'
