#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — git ls-files discovery fast path + kill-switch globstar (Cases T/U).
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case T: git-discovery fast path (tracked + untracked, gitignored skip) --
# When ROOT_DIR is a git work-tree root the runner discovers via `git ls-files`
# (+ --others --exclude-standard) instead of the dotglob globstar — reading the
# index rather than walking node_modules/.git. Verify it finds tracked AND
# untracked-unignored tests and skips a test under a .gitignore'd dir.
if command -v git >/dev/null 2>&1; then
  GITFIX="$TEST_TMPDIR/gitfix"
  rm -rf "$GITFIX"
  mkdir -p "$GITFIX/ignored"
  (
    cd "$GITFIX" || exit 1
    git init -q
    git config user.email 'selftest@example.invalid'
    git config user.name 'selftest'
    printf 'ignored/\n' >.gitignore
    printf '#!/usr/bin/env bash\nprintf "PASS: [1] tracked\\n"\nexit 0\n' >tracked.test.sh
    git add .gitignore tracked.test.sh
    git commit -qm init
    printf '#!/usr/bin/env bash\nprintf "PASS: [1] untracked\\n"\nexit 0\n' >untracked.test.sh
    printf '#!/usr/bin/env bash\nprintf "PASS: [1] gi\\n"\nexit 0\n' >ignored/gitignored.test.sh
  )
  OUT=$(bash "$RUNNER" "$GITFIX" 2>&1)
  RC=$?
  assert_exit "T: git-discovery fixture exits 0" 0 "$RC"
  assert_contains "T: discovers tracked + untracked-unignored (2 passed)" "$OUT" "2 passed"
  assert_contains "T: tracked test discovered" "$OUT" "tracked.test.sh"
  assert_contains "T: untracked-unignored test discovered" "$OUT" "untracked.test.sh"
  assert_not_contains "T: gitignored test excluded" "$OUT" "gitignored.test.sh"

  # --- Case U: kill switch forces globstar (no .gitignore awareness) ---------
  # BASH_TEST_GIT_DISCOVERY_ENABLED=false reverts to the tree-walk path, which
  # honours only the hardcoded filter — so it discovers the gitignored test too.
  OUT=$(BASH_TEST_GIT_DISCOVERY_ENABLED=false bash "$RUNNER" "$GITFIX" 2>&1)
  RC=$?
  assert_exit "U: kill-switch globstar fixture exits 0" 0 "$RC"
  assert_contains "U: globstar discovers all three incl. gitignored (3 passed)" "$OUT" "3 passed"
  assert_contains "U: gitignored test discovered by globstar" "$OUT" "gitignored.test.sh"
  rm -rf "$GITFIX"
else
  skip_case "T/U: git not on PATH — git-discovery fast path not exercisable"
fi

report
