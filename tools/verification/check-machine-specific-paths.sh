#!/usr/bin/env bash
# Fail CI when tracked files contain machine-specific absolute paths.
# Allows placeholder examples such as C:\Users\<user>\ and <repo-root>/...
#
# Argv contract:
#   - No args (CI / standalone): scan all tracked files matching the
#     extension allowlist below, minus the exclusion list.
#   - Positional args (pre-push push-range): intersect $@ with the
#     full-tree allowlist (extension allowlist - exclusion list), then
#     grep only that intersection. Empty intersection => clean exit 0.
#
# Push-range scoping rationale: pre-commit hardcoded-path-check vets
# staged blobs. Pre-push scoped to {push_files} (lefthook upstream
# template — https://lefthook.dev/configuration/run) catches the same
# failure class for files about to ship without trapping unrelated WIP.
# CI keeps the full-tree scan as the non-bypassable backstop.

set -euo pipefail

# Source the shared machine-path pattern bodies (SSOT). The lib is a pure
# function/constant library — no top-level side effects on source.
# shellcheck source=../shared/path-detection/hardcoded-path-patterns.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/path-detection/hardcoded-path-patterns.sh"

FAILED=0
PATH_BOUNDARY="(^|[[:space:]\"'\`(=]|file://)"
MACOS_HOME_PATTERN="${PATH_BOUNDARY}${HPP_MACOS_USER_BODY}"
LINUX_HOME_PATTERN="${PATH_BOUNDARY}${HPP_LINUX_USER_BODY}"

# Resolve scan set ONCE, outside run_check, so multiple pattern passes
# share the intersection result rather than recomputing it. SCAN_PATHS
# becomes the pathspec list passed to `git grep`.
declare -a SCAN_PATHS=(
  '*.cs'
  '*.csproj'
  '*.json'
  '*.jsonc'
  '*.js'
  '*.jsx'
  '*.md'
  '*.prompt.md'
  '*.props'
  '*.ps1'
  '*.psm1'
  '*.py'
  '*.sh'
  '*.slnx'
  '*.targets'
  '*.toml'
  '*.ts'
  '*.tsx'
  '*.yaml'
  '*.yml'
  ':(exclude).vs/**'
  # .work prose (.md) quotes real paths as evidence; structured .work content is
  # scanned. Don't re-broaden to .work/** (locked: P3-A/B/C in the fulltree test).
  ':(exclude).work/*.md'
  ':(exclude)artifacts/**'
  ':(exclude)**/bin/**'
  ':(exclude)**/obj/**'
  ':(exclude)tests/**/Log/**'
  ':(exclude).claude/skills/onlocation/references/**'
  ':(exclude).cursor/hooks/examples/*'
  ':(exclude).lefthook/pre-commit/hardcoded-path-check.sh'
  ':(exclude)tools/verification/check-machine-specific-paths.sh'
  ':(exclude)tools/shared/path-detection/hardcoded-path-patterns.sh'
  ':(exclude)tools/shared/path-detection/hardcoded-path-patterns.test.sh'
  ':(exclude).lefthook/pre-push/hardcoded-path-fulltree.test.sh'
  ':(exclude)*test-report-v*.md'
)

if (($# > 0)); then
  # Push-range mode: intersect $@ with the full-tree allowlist.
  # `git ls-files -- "${SCAN_PATHS[@]}"` enumerates the allowlist; we
  # shell-intersect against $@. Empty intersection => clean exit 0
  # (no allowed files in the push range — nothing to scan).
  declare -A allowed=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && allowed["$f"]=1
  done < <(git ls-files -- "${SCAN_PATHS[@]}")

  scoped=()
  for f in "$@"; do
    [[ -n "${allowed[$f]:-}" ]] && scoped+=("$f")
  done

  if ((${#scoped[@]} == 0)); then
    echo "No machine-specific absolute paths detected."
    exit 0
  fi

  # Re-bind SCAN_PATHS to the scoped intersection for run_check.
  SCAN_PATHS=("${scoped[@]}")
fi

run_check() {
  local label=$1
  local pattern=$2
  local matches

  matches=$(
    git grep -nIE "$pattern" -- "${SCAN_PATHS[@]}" | head -20 || true
  )

  if [[ -n "$matches" ]]; then
    echo "Machine-specific path detected (${label}):" >&2
    echo "$matches" >&2
    echo "" >&2
    FAILED=1
  fi
}

# OS home paths (with placeholders excluded by the character class).
run_check "Windows user path" "$HPP_WIN_USER_BODY"
run_check "macOS user path" "$MACOS_HOME_PATTERN"
run_check "Linux user path" "$LINUX_HOME_PATTERN"

# Repo checkout roots (plain and escaped backslash forms).
run_check "Windows repo path" "$HPP_WIN_REPO_BODY"
run_check "Escaped Windows repo path" "$HPP_ESCAPED_WIN_REPO_BODY"

if [[ "$FAILED" -ne 0 ]]; then
  echo "Use portable placeholders (<repo-root>, <workshop-repo-root>, <user>) or relative paths." >&2
  exit 1
fi

echo "No machine-specific absolute paths detected."
