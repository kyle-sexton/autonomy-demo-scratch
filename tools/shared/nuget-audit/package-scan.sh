# shellcheck shell=bash
# Shared NuGet vulnerable/deprecated package scan + flatten for the hook and
# lefthook consumers. Library — NOT executable, no shebang. Source via:
#   source "$(dirname "${BASH_SOURCE[0]}")/../../tools/shared/nuget-audit/package-scan.sh"
#
# Consumers (derive on demand — grep -l 'nuget-audit/package-scan' across
# .claude/hooks + .lefthook):
#   .claude/hooks/dependency-hygiene.sh          (PostToolUse — parallel vuln+dep)
#   .claude/hooks/dependency-context-keywords.sh (UserPromptSubmit — 60s cache)
#   .lefthook/pre-push/vulnerability-warning.sh  (pre-push — 30s timeout)
#
# Contract: the scan helpers emit raw `dotnet list package` JSON to STDOUT
# only. Callers own redirection, backgrounding, caching, the timeout VALUE,
# and every downstream formatting/jq pass. The lib owns the scan invocation +
# the flatten fragment; it never owns orchestration. Modeled on the sibling
# tools/shared/path-detection/hardcoded-path-patterns.sh.

# nuget_audit::scan_vulnerable <sln> [timeout_secs] [dotnet_bin]
#
# Emits `dotnet list <sln> package --vulnerable --include-transitive --format
# json` to stdout. When timeout_secs is non-empty, the dotnet invocation is
# wrapped in `timeout <secs>` — timeout wraps the external dotnet binary (a
# shell function cannot be wrapped), so the value is caller-owned but the
# mechanism rides here. dotnet_bin defaults to `dotnet`; callers thread their
# own per-consumer override (DEPENDENCY_*_HOOK_DOTNET) through it.
nuget_audit::scan_vulnerable() {
  local sln="${1:?nuget_audit::scan_vulnerable: sln required}"
  local timeout_secs="${2:-}" dotnet_bin="${3:-dotnet}"
  if [[ -n "$timeout_secs" ]]; then
    timeout "$timeout_secs" "$dotnet_bin" list "$sln" package \
      --vulnerable --include-transitive --format json
  else
    "$dotnet_bin" list "$sln" package \
      --vulnerable --include-transitive --format json
  fi
}

# nuget_audit::scan_deprecated <sln> [dotnet_bin]
#
# Emits `dotnet list <sln> package --deprecated --format json` to stdout.
nuget_audit::scan_deprecated() {
  local sln="${1:?nuget_audit::scan_deprecated: sln required}"
  local dotnet_bin="${2:-dotnet}"
  "$dotnet_bin" list "$sln" package --deprecated --format json
}

# NUGET_AUDIT_FLATTEN_JQ — a jq pipeline fragment. Given raw scan JSON on
# input, it streams each top-level + transitive package as an object augmented
# with its owning project's path under `project_path`, so a single fragment
# serves every consumer: callers that need the project read `.project_path`;
# callers that don't simply ignore it (the field never reaches their
# length/.id/unique/string-map). Wrap in `[ ... ]` and append your formatting.
# Uses `.projects[]` (no `?`) so malformed/absent `.projects` surfaces as a jq
# error → the caller's empty-output path (its "unavailable"/"none"/silent
# branch), preserving the strictest consumer's behavior.
# Interpolate via single-quote concatenation to keep the caller's own jq
# literal:  jq -r '['"$NUGET_AUDIT_FLATTEN_JQ"' | ...your formatting... ]'
# SC2016: $project_path is a jq variable (intentionally literal, not bash).
# SC2034: the var is consumed by sourcing scripts, not within this lib.
# shellcheck disable=SC2016,SC2034
NUGET_AUDIT_FLATTEN_JQ='.projects[] | .path as $project_path | select(.frameworks) | .frameworks[] | (.topLevelPackages // []) + (.transitivePackages // []) | .[]? | . + {project_path: $project_path}'
