#!/usr/bin/env bash
# Tests for tools/lint/run-lint.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

LINT="$SCRIPT_DIR/run-lint.sh"
FAILED=0

assert_exit "--help exits 0" 0 "$(
  bash "$LINT" --help >/dev/null 2>&1
  echo $?
)"

out="$(bash "$LINT" --dry-run --ecosystem markdown 2>/dev/null || true)"
assert_contains "markdown ecosystem" "$out" "Ecosystem: markdown"
assert_contains "planned status" "$out" "Status: planned"
assert_contains "summary line" "$out" "Summary:"

dotnet_out="$(bash "$LINT" --dry-run --ecosystem dotnet 2>/dev/null || true)"
assert_contains "dotnet ecosystem" "$dotnet_out" "Ecosystem: dotnet"
assert_contains "dotnet resolves solution anchor" "$dotnet_out" "Medley.slnx"

cross="$(bash "$LINT" --dry-run --ecosystem cross-cutting 2>/dev/null || true)"
assert_contains "cross-cutting typos" "$cross" "typos"
assert_contains "cross-cutting gitleaks" "$cross" "gitleaks"
# editorconfig-checker is dispatched via the resolved $EC_BIN placeholder, so the
# literal name lives in the config, not the substituted command.
cross_yaml="$(cat "$REPO_ROOT/.claude/ecosystems/cross-cutting.yaml")"
assert_contains "cross-cutting declares editorconfig-checker" "$cross_yaml" "editorconfig-checker"

fix_out="$(bash "$LINT" --fix --dry-run --ecosystem powershell 2>/dev/null || true)"
assert_contains "fix without auto-fix skips" "$fix_out" "no auto-fix available for powershell"

all_out="$(bash "$LINT" --dry-run --all 2>/dev/null || true)"
assert_contains "dry-run --all includes yaml" "$all_out" "Ecosystem: yaml"

yaml_out="$(bash "$LINT" --dry-run --ecosystem yaml 2>/dev/null || true)"
assert_contains "yaml ecosystem" "$yaml_out" "Ecosystem: yaml"
assert_contains "yaml multi-command check parses" "$yaml_out" "actionlint"

assert_exit "unknown arg exits 2" 2 "$(
  bash "$LINT" --bogus >/dev/null 2>&1
  echo $?
)"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: run-lint.sh tests passed"
