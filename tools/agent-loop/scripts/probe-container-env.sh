#!/usr/bin/env bash
# Emit JSON describing container hook/runtime readiness for agent-loop observability.
# stdout: single JSON document. Diagnostics go to stderr.
set -uo pipefail

WORKSPACE="${CLAUDE_PROJECT_DIR:-/workspace}"
cd "$WORKSPACE" 2>/dev/null || {
  echo '{"schemaVersion":1,"error":"workspace_unreadable","workspace":"'"$WORKSPACE"'"}' >&2
  echo '{"schemaVersion":1,"error":"workspace_unreadable"}'
  exit 0
}

log() {
  echo "$*" >&2
}

dep_json_object() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    local version=""
    version=$("$name" --version 2>/dev/null | head -n 1 || echo "present")
    version="${version//\"/\\\"}"
    printf '{"name":"%s","present":true,"version":"%s"}' "$name" "$version"
  else
    printf '{"name":"%s","present":false}' "$name"
  fi
}

DEP_NAMES=(bash git jq rg curl node dotnet shellcheck shfmt lefthook gh pwsh)
deps="["
first_dep=1
for dep in "${DEP_NAMES[@]}"; do
  if [[ "$first_dep" -eq 0 ]]; then
    deps+=","
  fi
  deps+=$(dep_json_object "$dep")
  first_dep=0
done
deps+="]"

has_cursor_hooks="false"
has_claude_settings="false"
cursor_hooks_file_present="false"
cursor_hooks_empty="false"
settings_has_hooks_key="false"
if [[ -f ".cursor/hooks.json" ]]; then
  has_cursor_hooks="true"
  cursor_hooks_file_present="true"
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.hooks == {} or .hooks == null' .cursor/hooks.json >/dev/null 2>&1; then
      cursor_hooks_empty="true"
    fi
  fi
fi
if [[ -f ".claude/settings.json" ]]; then
  has_claude_settings="true"
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.hooks != null' .claude/settings.json >/dev/null 2>&1; then
      settings_has_hooks_key="true"
    fi
  fi
fi

hook_probe_exit="null"
hook_probe_stderr=""
hook_path=".claude/hooks/branch-protection.sh"
if [[ -f "$hook_path" ]]; then
  test_input='{"tool_name":"Write","tool_input":{"file_path":"'"$WORKSPACE"'/README.md","content":"hello"}}'
  hook_stderr_file="$(mktemp)"
  set +e
  printf '%s' "$test_input" | bash "$hook_path" 2>"$hook_stderr_file"
  hook_probe_exit=$?
  set -e
  hook_probe_stderr=$(head -c 500 "$hook_stderr_file" | tr '\n' ' ')
  rm -f "$hook_stderr_file"
else
  hook_probe_stderr="hook script missing: $hook_path"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo '{"schemaVersion":1,"error":"jq_missing"}'
  exit 0
fi

hook_exit_json=$hook_probe_exit
if [[ "$hook_probe_exit" == "null" ]]; then
  hook_exit_json=null
fi

git_layout="${AGENT_LOOP_GIT_BRIDGE_LAYOUT:-none}"
git_mode="${AGENT_LOOP_GIT_BRIDGE_MODE:-unavailable}"
if [[ "$git_layout" == "none" ]]; then
  if [[ -d ".git" ]]; then
    git_layout="plain"
    git_mode="read-write"
  elif [[ -f ".git" ]]; then
    git_layout="linked"
  fi
fi

git_status_exit="null"
if command -v git >/dev/null 2>&1; then
  set +e
  git -C "$WORKSPACE" rev-parse --is-inside-work-tree >/dev/null 2>&1
  git_status_exit=$?
  set -e
fi

jq -n \
  --argjson schemaVersion 1 \
  --arg workspace "$WORKSPACE" \
  --argjson dependencies "$deps" \
  --argjson hasCursorHooks "$([[ $has_cursor_hooks == true ]] && echo true || echo false)" \
  --argjson hasClaudeSettings "$([[ $has_claude_settings == true ]] && echo true || echo false)" \
  --argjson settingsHasHooksKey "$([[ $settings_has_hooks_key == true ]] && echo true || echo false)" \
  --argjson cursorHooksFilePresent "$([[ $cursor_hooks_file_present == true ]] && echo true || echo false)" \
  --argjson cursorHooksEmpty "$([[ $cursor_hooks_empty == true ]] && echo true || echo false)" \
  --arg hookScript "$hook_path" \
  --arg hookStderr "$hook_probe_stderr" \
  --argjson hookExitCode "${hook_exit_json:-null}" \
  --arg gitLayout "$git_layout" \
  --arg gitMode "$git_mode" \
  --argjson gitStatusExit "${git_status_exit:-null}" \
  '{
    schemaVersion: $schemaVersion,
    workspace: $workspace,
    dependencies: $dependencies,
    hookConfig: {
      hasCursorHooks: $hasCursorHooks,
      hasClaudeSettings: $hasClaudeSettings,
      settingsHasHooksKey: $settingsHasHooksKey,
      cursorHooksFilePresent: $cursorHooksFilePresent,
      cursorHooksEmpty: $cursorHooksEmpty
    },
    hookProbe: {
      script: $hookScript,
      exitCode: $hookExitCode,
      stderr: $hookStderr
    },
    gitBridge: {
      layout: $gitLayout,
      mode: $gitMode,
      gitStatusExit: $gitStatusExit
    }
  }'
