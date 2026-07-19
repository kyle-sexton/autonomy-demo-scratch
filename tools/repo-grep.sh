#!/usr/bin/env bash
# Scoped content search for repo audits — avoids repo-root rg/grep -rn over heavy paths.
#
# Default: git grep over durable roots (excludes .work/ unless --include-work).
# --engine rg: ripgrep (respects repo .ignore + --max-filesize 1M).
#
# Usage:
#   repo-grep.sh [options] PATTERN
#   repo-grep.sh --help
#
# Exit: 0 match, 1 no match, 2 usage/error.
set -euo pipefail

ENGINE="git"
LITERAL=0
INCLUDE_WORK=0
FULL_TREE=0
MAX_COUNT=""
PATTERN=""

usage() {
  cat <<'EOF'
repo-grep.sh — scoped content search for agent audits.

Usage:
  repo-grep.sh [options] PATTERN

Options:
  --engine git|rg   Search backend (default: git)
  --literal, -F     Literal string match (not regex)
  --include-work    Include .work/ in git engine scope
  --full-tree       Search entire repo (dangerous on Windows — opt-in only)
  --max-count N     Limit output lines (git: -m; rg: -m)
  -h, --help        Show this help

Examples:
  bash tools/repo-grep.sh -F 'MyToken'
  bash tools/repo-grep.sh --engine rg -F 'MyToken'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      ENGINE="${2:-}"
      shift 2
      ;;
    --literal | -F)
      LITERAL=1
      shift
      ;;
    --include-work)
      INCLUDE_WORK=1
      shift
      ;;
    --full-tree)
      FULL_TREE=1
      shift
      ;;
    --max-count)
      MAX_COUNT="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "repo-grep.sh: unknown option '$1'" >&2
      exit 2
      ;;
    *)
      if [[ -z "$PATTERN" ]]; then
        PATTERN="$1"
        shift
      else
        break
      fi
      ;;
  esac
done

if [[ -z "$PATTERN" ]]; then
  echo "repo-grep.sh: PATTERN required" >&2
  exit 2
fi

extra_paths=("$@")

case "$ENGINE" in
  git | rg) ;;
  *)
    echo "repo-grep.sh: --engine must be git or rg" >&2
    exit 2
    ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')" || {
  echo "repo-grep.sh: not a git repository" >&2
  exit 2
}
cd "$repo_root"

git_paths=(
  .claude .codex .cursor docs tools mcp-servers apps libs tests
  AGENTS.md CLAUDE.md README.md REVIEW.md lefthook.yml
)
if [[ "$INCLUDE_WORK" -eq 1 || "$FULL_TREE" -eq 1 ]]; then
  git_paths+=(".work")
fi

run_git_grep() {
  local -a args=()
  if [[ "$LITERAL" -eq 1 ]]; then
    args+=(-F)
  else
    args+=(-E)
  fi
  if [[ -n "$MAX_COUNT" ]]; then
    args+=(-m "$MAX_COUNT")
  fi
  # MSYS_NO_PATHCONV=1: on Windows/Git Bash, MSYS rewrites a leading-slash argument
  # (e.g. a "/foo" search pattern) into a Windows path before git.exe sees it, so the
  # search silently matches nothing. Disabling path conversion for the git subprocess
  # is a no-op on Linux/macOS. Relative pathspecs below are unaffected.
  if [[ ${#extra_paths[@]} -gt 0 ]]; then
    MSYS_NO_PATHCONV=1 git grep "${args[@]}" -e "$PATTERN" -- "${extra_paths[@]}" || return 1
  elif [[ "$FULL_TREE" -eq 1 ]]; then
    MSYS_NO_PATHCONV=1 git grep "${args[@]}" -e "$PATTERN" -- . || return 1
  else
    MSYS_NO_PATHCONV=1 git grep "${args[@]}" -e "$PATTERN" -- "${git_paths[@]}" || return 1
  fi
}

run_rg() {
  if ! command -v rg >/dev/null 2>&1; then
    echo "repo-grep.sh: rg not found" >&2
    exit 2
  fi
  local -a args=(--max-filesize 1M)
  if [[ "$LITERAL" -eq 1 ]]; then
    args+=(-F)
  fi
  if [[ -n "$MAX_COUNT" ]]; then
    args+=(-m "$MAX_COUNT")
  fi
  if [[ ${#extra_paths[@]} -gt 0 ]]; then
    rg "${args[@]}" -e "$PATTERN" -- "${extra_paths[@]}" || return 1
  elif [[ "$FULL_TREE" -eq 1 ]]; then
    rg "${args[@]}" -e "$PATTERN" || return 1
  else
    local -a globs=(
      -g '*.md' -g '*.mdc' -g '*.sh' -g '*.bash' -g '*.ps1'
      -g '*.ts' -g '*.tsx' -g '*.js' -g '*.jsx' -g '*.json'
      -g '*.cs' -g '*.csproj' -g '*.yml' -g '*.yaml' -g '*.toml'
      -g 'AGENTS.md' -g 'CLAUDE.md' -g 'REVIEW.md' -g 'README.md'
    )
    if [[ "$INCLUDE_WORK" -eq 1 ]]; then
      rg "${args[@]}" "${globs[@]}" -e "$PATTERN" || return 1
    else
      rg "${args[@]}" "${globs[@]}" -g '!.work/**' -e "$PATTERN" || return 1
    fi
  fi
}

case "$ENGINE" in
  git) run_git_grep ;;
  rg) run_rg ;;
  *)
    echo "repo-grep.sh: internal error — unknown engine '$ENGINE'" >&2
    exit 2
    ;;
esac
