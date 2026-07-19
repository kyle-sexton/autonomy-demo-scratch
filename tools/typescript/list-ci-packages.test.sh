#!/usr/bin/env bash
# Regression tests for tools/typescript/list-ci-packages.sh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="$(git rev-parse --show-toplevel | tr -d '\r')"
source "$REPO_ROOT/tests/shell/lib.sh"

SCRIPT="$SCRIPT_DIR/list-ci-packages.sh"

assert_contains "help mentions --json" \
  "$("$SCRIPT" --help)" \
  "--json"

mapfile -t PACKAGES < <("$SCRIPT")
assert_eq "discovers seven CI packages" "7" "${#PACKAGES[@]}"

for expected in \
  mcp-servers/github-events/node \
  tests/e2e \
  tools/agent-loop \
  .claude/skills/course-digest/extraction \
  tools/shared/repo-analysis \
  tools/shared/video-digestion \
  .claude/skills/youtube/extraction; do
  found=false
  for pkg in "${PACKAGES[@]}"; do
    [[ "$pkg" == "$expected" ]] && found=true && break
  done
  assert_eq "lists $expected" "true" "$found"
done

DETAIL=$("$SCRIPT" --json-detail)
assert_contains "json-detail includes agent-loop" "$DETAIL" '"path":"tools/agent-loop"'
assert_contains "json-detail marks agent-loop vitest" "$DETAIL" '"vitest":true'
assert_contains "json-detail marks e2e non-vitest" "$DETAIL" '"path":"tests/e2e","vitest":false'

JSON=$("$SCRIPT" --json)
assert_contains "json is array" "$JSON" '['

npm_only=$("$SCRIPT" --include-npm-only)
assert_contains "npm-only includes runner-policy" "$npm_only" '.github/standards/runner-policy'
assert_not_contains "npm-only excludes repo root abspath" "$npm_only" "$REPO_ROOT"
abs_path=false
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if [[ "$line" == /* || "$line" =~ ^[A-Za-z]: ]]; then
    abs_path=true
    break
  fi
done <<<"$npm_only"
assert_eq "npm-only emits relative paths only" "false" "$abs_path"

[[ $FAILED -eq 0 ]] || exit 1
