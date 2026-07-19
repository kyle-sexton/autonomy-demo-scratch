#!/usr/bin/env bash
# Tests for check-path-exclude-families.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

CHECK="$SCRIPT_DIR/check-path-exclude-families.sh"
FAILED=0

help_code=$(
  bash "$CHECK" --help >/dev/null 2>&1
  echo $?
)
assert_exit "--help exits 0" 0 "$help_code"

check_code=$(
  bash "$CHECK" >/dev/null 2>&1
  echo $?
)
assert_exit "family anchors in sync" 0 "$check_code"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
make_repo "$TMP"
cp "$REPO_ROOT/.ignore" "$TMP/.ignore"
sed -i '/\.claude\/skills\/course-digest\/data\//d' "$TMP/.ignore"
cp "$REPO_ROOT/.cursorindexingignore" "$TMP/.cursorindexingignore"
cp "$REPO_ROOT/_typos.toml" "$TMP/_typos.toml"
git -C "$TMP" add .ignore .cursorindexingignore _typos.toml
git -C "$TMP" commit -qm "seed exclude consumers"

drift_out="$(
  cd "$TMP" && bash "$CHECK" 2>&1
)"
drift_rc=$?
assert_exit "missing anchor exits 1" 1 "$drift_rc"
assert_contains "missing anchor message" "$drift_out" "missing anchor"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: check-path-exclude-families.sh tests passed"
