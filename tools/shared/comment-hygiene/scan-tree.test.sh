#!/usr/bin/env bash
# Regression tests for tools/shared/comment-hygiene/scan-tree.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_TREE="$SCRIPT_DIR/scan-tree.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

make_fixture_repo() {
  local root="$1"
  mkdir -p "$root/apps" "$root/review" "$root/tools/shared/comment-hygiene"
  cp "$SCRIPT_DIR/comment-hygiene-patterns.sh" "$root/tools/shared/comment-hygiene/"
  cp "$SCAN_TREE" "$root/tools/shared/comment-hygiene/scan-tree.sh"
  chmod +x "$root/tools/shared/comment-hygiene/scan-tree.sh"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "scan-tree@test"
    git config user.name "scan-tree"
  )
}

add_tracked() {
  local root="$1" path="$2" content="$3"
  mkdir -p "$(dirname "$root/$path")"
  printf '%s\n' "$content" >"$root/$path"
  (cd "$root" && git add "$path")
}

fixture="$TEST_TMPDIR/fixture"
make_fixture_repo "$fixture"

add_tracked "$fixture" "apps/clean.sh" '# wiring only'
add_tracked "$fixture" "apps/bad.sh" '# TODO: remove before merge'
add_tracked "$fixture" "review/example.sh" '# TODO: teaching example in review'
add_tracked "$fixture" "apps/phase.sh" '# --- Phases: mixed DONE+DOING+TODO → in-progress ---'
(
  cd "$fixture" && git commit -qm "fixture"
)

out=$(TEST_REPO_ROOT="$fixture" bash "$SCAN_TREE" 2>&1) || rc=$?
rc=${rc:-0}
assert_exit "violation fixture exits 1" 1 "$rc"
assert_contains "reports todo violation" "$out" "apps/bad.sh"
assert_contains "warning-marker in output" "$out" "warning-marker"
assert_not_contains "review slice excluded" "$out" "review/example.sh"
assert_not_contains "phase grammar allowed" "$out" "apps/phase.sh"

clean_fixture="$TEST_TMPDIR/clean"
make_fixture_repo "$clean_fixture"
add_tracked "$clean_fixture" "apps/ok.ts" '// upstream: anthropics/claude-code#11897'
(
  cd "$clean_fixture" && git commit -qm "clean"
)
rc=0
out=$(TEST_REPO_ROOT="$clean_fixture" bash "$SCAN_TREE" 2>&1) || rc=$?
assert_exit "clean fixture exits 0" 0 "$rc"
assert_contains "clean summary" "$out" "clean"

out=$("$SCAN_TREE" --help 2>&1)
assert_contains "help mentions usage" "$out" "Usage:"

echo "scan-tree.test.sh: all cases passed"
