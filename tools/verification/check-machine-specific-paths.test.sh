#!/usr/bin/env bash
# shellcheck disable=SC2154
# Regression tests for tools/verification/check-machine-specific-paths.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-machine-specific-paths.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

run_in_tracked_repo() {
  local root="$1"
  shift

  mkdir -p "$root"
  (
    cd "$root" || exit 2
    git init -q
    git config commit.gpgsign false
    "$@"
  )
}

run_path_check() {
  local root="$1"
  (
    cd "$root" || exit 2
    bash "$SCRIPT"
  ) 2>&1
}

# --- Case A: URL paths containing /home/ are not filesystem paths ------------

ROOT_A="$TEST_TMPDIR/repo-a"
run_in_tracked_repo "$ROOT_A" bash -c '
  segment="home"
  user="alice"
  printf "https://example.test/%s/%s/docs/\n" "$segment" "$user" > data.json
  git add data.json
'

OUT_A=$(run_path_check "$ROOT_A")
assert_exit "case A: URL /home segment exits zero" "0" "$?"
assert_contains "case A: clean message emitted" "$OUT_A" "No machine-specific absolute paths detected."

# --- Case B: real Linux home paths are still rejected ------------------------

ROOT_B="$TEST_TMPDIR/repo-b"
run_in_tracked_repo "$ROOT_B" bash -c '
  slash="/"
  printf "%s\n" "${slash}home${slash}alice${slash}repo" > sample.md
  git add sample.md
'

OUT_B=$(run_path_check "$ROOT_B" || true)
assert_contains "case B: real Linux home path is rejected" "$OUT_B" "Linux user path"

# --- Case C: file:// URIs containing /home/ are filesystem paths, not URLs ---

ROOT_C="$TEST_TMPDIR/repo-c"
run_in_tracked_repo "$ROOT_C" bash -c '
  protocol="file://"
  slash="/"
  printf "%s%shome%salice%srepo%s\n" "$protocol" "$slash" "$slash" "$slash" "$slash" > config.json
  git add config.json
'

OUT_C=$(run_path_check "$ROOT_C" || true)
assert_contains "case C: file:// URI Linux home path is rejected" "$OUT_C" "Linux user path"

# --- Report ------------------------------------------------------------------

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d checks passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
