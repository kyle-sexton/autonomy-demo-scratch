#!/usr/bin/env bash
# Provider-neutral worktree setup — SSOT for post-create and session-start provisioning.
# Pipelines: cursor, claude-session-start-main, claude-session-start-worktree, agent-loop-post-create
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/copy-worktreeinclude.sh
source "$SCRIPT_DIR/lib/copy-worktreeinclude.sh"
# shellcheck source=lib/dotnet-restore.sh
source "$SCRIPT_DIR/lib/dotnet-restore.sh"
# shellcheck source=lib/fetch-marker.sh
source "$SCRIPT_DIR/lib/fetch-marker.sh"
# shellcheck source=lib/scan-orphan-worktrees.sh
source "$SCRIPT_DIR/lib/scan-orphan-worktrees.sh"
# shellcheck source=lib/resolve-layout.sh
source "$SCRIPT_DIR/lib/resolve-layout.sh"

LOG_PREFIX='[worktree-setup]'
SETUP_CWD="${SETUP_CWD:-.}"
MAIN_ROOT="${MAIN_ROOT:-}"
WORKTREE_ROOT="${WORKTREE_ROOT:-}"
BARE_HUB_LAYOUT="${BARE_HUB_LAYOUT:-false}"

usage() {
  cat <<'EOF'
Usage: setup-worktree.sh --pipeline <name> [options]

Pipelines:
  cursor                        Cursor worktree auto-setup (soft-fail)
  claude-session-start          Claude SessionStart orchestrator (main + worktree phases)
  claude-session-start-main     Phase 1 main-repo bootstrap (soft-fail)
  claude-session-start-worktree Phase 2 worktree runtime (soft-fail)
  agent-loop-post-create        Post git worktree add (soft-fail)

Options:
  --pipeline <name>   Required pipeline selector
  --cwd <path>        Git context directory (default: pwd)
  --worktree-root <p> Worktree root (default: git toplevel of --cwd)
  --main-root <p>     Main checkout root (cursor/agent-loop/session-start)
  --bare-hub          Bare-clone hub layout (skips Phase 1 main bootstrap)
  --help              Show this help

Environment:
  ROOT_WORKTREE_PATH  Cursor main checkout (cursor pipeline)
  BOOTSTRAP_SH        Override bootstrap script path (tests)

Session-start pipelines emit hook context lines on stdout only; operational logs go to stderr.
EOF
}

log_step() { printf '%s %s\n' "$LOG_PREFIX" "$1" >&2; }
log_warn() { printf '%s WARN %s\n' "$LOG_PREFIX" "$1" >&2; }

setup_ctx_line() {
  [[ -n "${1:-}" ]] && printf '%s\n' "$1"
}

# Emit each non-empty line of a newline-accumulated block as a context line.
emit_ctx_block() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && setup_ctx_line "$line"
  done < <(printf '%s' "$1")
}

bootstrap_sh() {
  if [[ -n "${BOOTSTRAP_SH:-}" ]]; then
    printf '%s' "$BOOTSTRAP_SH"
    return 0
  fi
  local root="${1:-.}"
  if [[ -f "$root/tools/bootstrap.sh" ]]; then
    printf '%s/tools/bootstrap.sh' "$root"
    return 0
  fi
  return 1
}

# run_bootstrap <target-root> <script-root> <quiet:0|1> <emit-stdout:0|1>
run_bootstrap() {
  local target_root="${1:-.}" script_root="${2:-$1}" quiet="${3:-0}" emit="${4:-0}"
  local bs args=() out
  [[ "$quiet" == "1" ]] && args+=(--quiet)
  args+=("$target_root")
  if bs=$(bootstrap_sh "$script_root"); then
    out=$(bash "$bs" "${args[@]}" 2>&1) || log_warn "bootstrap reported issues (non-fatal)"
    if [[ "$emit" == "1" && -n "$out" ]]; then
      while IFS= read -r line; do
        setup_ctx_line "$line"
      done <<<"$out"
    fi
    return 0
  fi
  log_warn "bootstrap.sh not found under $script_root"
  return 0
}

step_copy_includes() {
  local source="${1:-}" dest="${2:-.}"
  worktree_lib_copy_worktreeinclude "$source" "$dest" "$LOG_PREFIX"
}

step_fix_main_upstream() {
  local main_root="${1:-}"
  local upstream
  upstream=$(git -C "$main_root" config branch.main.remote 2>/dev/null | tr -d '\r')
  if [[ -z "$upstream" ]]; then
    if git -C "$main_root" rev-parse --verify origin/main >/dev/null 2>&1; then
      git -C "$main_root" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
      log_step "set branch.main upstream to origin/main"
    fi
  fi
}

# step_heal_git_filemode <cwd> <emit-ctx:0|1>
step_heal_git_filemode() {
  local cwd="${1:-.}" emit="${2:-0}"
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      local filemode
      filemode=$(git -C "$cwd" config --local --get core.filemode 2>/dev/null | tr -d '\r')
      if [[ "$filemode" != "false" ]]; then
        git -C "$cwd" config core.filemode false 2>/dev/null || true
        log_step "core.filemode reset to false (was ${filemode:-unset})"
        if [[ "$emit" == "1" ]]; then
          setup_ctx_line "core.filemode reset to false (was ${filemode:-unset}) — a Linux-side git (WSL/container bind mount) likely flipped the shared config; exec-bit phantom diffs cleared."
        fi
      fi
      ;;
    *) ;;
  esac
}

step_fetch_origin_main_bg() {
  local worktree_root="${1:-.}"
  local marker
  marker=$(worktree_lib_fetch_marker_file "$worktree_root") || true
  (
    if git -C "$worktree_root" fetch origin main --quiet 2>/dev/null; then
      if [[ -n "$marker" ]]; then
        mkdir -p "$(dirname "$marker")" 2>/dev/null || true
        printf '%s\n' "${EPOCHSECONDS:-$(date +%s)}" >"$marker" 2>/dev/null || true
      fi
    fi
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  log_step "backgrounded origin/main fetch"
}

# step_provision_worktree_bg <worktree_root> <bootstrap_script_root>
# Background the heavy worktree provisioning (dotnet restore + bootstrap prereq
# scan) so SessionStart returns promptly instead of blocking tens of seconds —
# mirrors step_fetch_origin_main_bg.
#
# Concurrency note: a foreground `dotnet build` the session may trigger in the
# first few seconds of a FRESH worktree (build auto-restores by default) can
# race the background restore on obj/project.assets.json; it is transient and
# retry-recoverable (re-run the build). Accepted for non-blocking startup.
# (No flock — it is absent on Git for Windows; concurrent same-hub restores are
# idempotent so serialization is unnecessary.)
step_provision_worktree_bg() {
  local worktree_root="${1:-.}" bootstrap_script_root="${2:-$1}"
  (
    if compgen -G "$worktree_root"/*.slnx >/dev/null 2>&1 && command -v dotnet >/dev/null 2>&1; then
      (cd "$worktree_root" && worktree_lib_dotnet_restore if-stale) || true
    fi
    run_bootstrap "$worktree_root" "$bootstrap_script_root" 1 0
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  log_step "backgrounded worktree provisioning (restore + bootstrap)"
}

step_orphan_advisory_ctx() {
  local cwd="${1:-}" main_root="${2:-}" common_dir="${3:-}" is_bare="${4:-false}"
  local count
  count=$(worktree_lib_count_orphan_worktrees "$main_root" "$common_dir" "$is_bare")
  if [[ "$count" -gt 0 ]]; then
    setup_ctx_line "$count orphaned worktree dir(s) — run /worktree cleanup to remove"
  fi
}

parse_main_root_from_porcelain() {
  worktree_lib_parse_main_root_from_porcelain "$1"
}

resolve_layout() {
  local cwd="${1:-.}" main_root="${MAIN_ROOT:-}" bare_hub="${BARE_HUB_LAYOUT:-false}" _layout
  mapfile -t _layout < <(parse_main_root_from_porcelain "$cwd")
  if [[ -z "$main_root" ]]; then
    main_root="${_layout[0]:-}"
  fi
  if [[ "$BARE_HUB_LAYOUT" != true && "${_layout[1]:-false}" == true ]]; then
    bare_hub=true
  fi
  printf '%s\n%s\n' "$main_root" "$bare_hub"
}

pipeline_cursor() {
  local main_root="${ROOT_WORKTREE_PATH:-${MAIN_ROOT:-}}"
  log_step "pipeline cursor"
  if [[ -z "$main_root" ]]; then
    log_warn "ROOT_WORKTREE_PATH unset — skipping .worktreeinclude copy"
  else
    step_copy_includes "$main_root" "."
  fi
  run_bootstrap "." "." 0 0
  if command -v dotnet >/dev/null 2>&1; then
    if worktree_lib_dotnet_restore always; then
      log_step "dotnet restore"
    else
      log_warn "dotnet restore reported issues (non-fatal)"
    fi
  fi
}

pipeline_claude_session_start_main() {
  local cwd="$SETUP_CWD" main_root bare_hub _layout
  mapfile -t _layout < <(resolve_layout "$cwd")
  main_root="${_layout[0]:-}"
  bare_hub="${_layout[1]:-false}"
  [[ -n "$main_root" ]] || return 0
  log_step "pipeline claude-session-start-main"
  if [[ "$bare_hub" != "true" ]]; then
    run_bootstrap "$main_root" "$main_root" 1 1
  fi
  step_fix_main_upstream "$main_root"
  step_heal_git_filemode "$cwd" 1
}

pipeline_claude_session_start_worktree() {
  local worktree_root="${WORKTREE_ROOT:-}"
  local main_root bootstrap_script_root actions="" warnings=""
  local common_dir is_bare=false _layout
  if [[ -z "$worktree_root" ]]; then
    worktree_root=$(git -C "$SETUP_CWD" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  fi
  worktree_root="${worktree_root//\\//}"
  [[ -n "$worktree_root" ]] || return 0
  mapfile -t _layout < <(resolve_layout "$SETUP_CWD")
  main_root="${_layout[0]:-${MAIN_ROOT:-}}"
  is_bare=false
  [[ "${_layout[1]:-false}" == true ]] && is_bare=true
  common_dir=$(git -C "$SETUP_CWD" rev-parse --git-common-dir 2>/dev/null | tr -d '\r')
  common_dir="${common_dir//\\//}"
  bootstrap_script_root="${main_root:-$worktree_root}"
  log_step "pipeline claude-session-start-worktree"
  step_heal_git_filemode "$SETUP_CWD" 1
  step_fetch_origin_main_bg "$worktree_root"
  actions+="  - Backgrounded origin/main fetch"$'\n'
  step_provision_worktree_bg "$worktree_root" "$bootstrap_script_root"
  actions+="  - Backgrounded .NET restore + prereq check"$'\n'

  if [[ -n "$actions" || -n "$warnings" ]]; then
    setup_ctx_line "Worktree auto-setup:"
    emit_ctx_block "$actions"
    if [[ -n "$warnings" ]]; then
      setup_ctx_line "Warnings:"
      emit_ctx_block "$warnings"
    fi
  fi
  if [[ -n "$main_root" ]]; then
    step_orphan_advisory_ctx "$SETUP_CWD" "$main_root" "$common_dir" "$is_bare"
  fi
}

pipeline_claude_session_start() {
  local main_root="" bare_hub=false is_worktree=false worktree_root="" _session
  mapfile -t _session < <(worktree_lib_detect_claude_session "$SETUP_CWD")
  main_root="${_session[0]:-}"
  bare_hub="${_session[1]:-false}"
  is_worktree="${_session[2]:-false}"
  worktree_root="${_session[3]:-}"
  [[ -n "$main_root" ]] || return 0

  MAIN_ROOT="$main_root"
  BARE_HUB_LAYOUT="$bare_hub"
  WORKTREE_ROOT="$worktree_root"
  log_step "pipeline claude-session-start"

  if [[ "$bare_hub" != "true" ]]; then
    pipeline_claude_session_start_main
  fi
  if [[ "$is_worktree" == "true" && -n "$worktree_root" ]]; then
    pipeline_claude_session_start_worktree
  fi
}

pipeline_agent_loop_post_create() {
  local main_root="${MAIN_ROOT:-}" worktree_root="${WORKTREE_ROOT:-.}"
  log_step "pipeline agent-loop-post-create"
  step_copy_includes "$main_root" "$worktree_root"
  run_bootstrap "$worktree_root" "${main_root:-$worktree_root}" 0 0
  (
    cd "$worktree_root" || exit 0
    if command -v dotnet >/dev/null 2>&1; then
      worktree_lib_dotnet_restore if-stale || log_warn "dotnet restore reported issues (non-fatal)"
    fi
  )
  step_heal_git_filemode "$worktree_root" 0
}

main() {
  local pipeline=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pipeline)
        pipeline="${2:-}"
        shift 2
        ;;
      --cwd)
        SETUP_CWD="${2:-}"
        shift 2
        ;;
      --worktree-root)
        WORKTREE_ROOT="${2:-}"
        shift 2
        ;;
      --main-root)
        MAIN_ROOT="${2:-}"
        shift 2
        ;;
      --bare-hub)
        BARE_HUB_LAYOUT=true
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        printf '%s unknown arg: %s\n' "$LOG_PREFIX" "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "$pipeline" ]]; then
    usage >&2
    exit 2
  fi

  case "$pipeline" in
    cursor) pipeline_cursor ;;
    claude-session-start) pipeline_claude_session_start ;;
    claude-session-start-main) pipeline_claude_session_start_main ;;
    claude-session-start-worktree) pipeline_claude_session_start_worktree ;;
    agent-loop-post-create) pipeline_agent_loop_post_create ;;
    *)
      printf '%s unknown pipeline: %s\n' "$LOG_PREFIX" "$pipeline" >&2
      exit 2
      ;;
  esac
  log_step "setup complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
