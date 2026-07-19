#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — RERUN_ALL_TRIGGERS shared-lib fallback + sparse -f guard (Cases V/W).
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case V: RERUN_ALL_TRIGGERS shared-lib entry forces full suite ------
# The pid-* / normalize-eol libs are consumed by PRODUCTION scripts whose
# *.test.sh files do NOT reference the lib basename, so the sibling/glob/
# text-grep dispatch rule would silently miss them on a lib edit. They are
# listed in RERUN_ALL_TRIGGERS so any such change re-runs the whole suite.
# Verify a change to one (pid-file-read.sh) trips the must-rerun-all fallback,
# NAMING that trigger, rather than running zero/partial tests.
if command -v git >/dev/null 2>&1; then
  VREPO="$TEST_TMPDIR/v-repo"
  rm -rf "$VREPO"
  mkdir -p "$VREPO/tools/shared/process-management"
  (
    cd "$VREPO" || exit 1
    git init --quiet --initial-branch=main
    git config user.email 'selftest@example.invalid'
    git config user.name 'selftest'
    git config commit.gpgsign false
    printf '#!/usr/bin/env bash\n# shared process-management lib stand-in\n' \
      >tools/shared/process-management/pid-file-read.sh
    printf '#!/usr/bin/env bash\nprintf "PASS: [1] alpha\\n"\nexit 0\n' >alpha.test.sh
    printf '#!/usr/bin/env bash\nprintf "PASS: [1] beta\\n"\nexit 0\n' >beta.test.sh
    git add -A
    git commit --quiet -m init
    git checkout --quiet -b feat-lib-edit
    printf '# edit\n' >>tools/shared/process-management/pid-file-read.sh
    git add tools/shared/process-management/pid-file-read.sh
    git commit --quiet -m edit-pid-lib
  )
  OUT=$(bash "$RUNNER" "$VREPO" --changed-since main 2>&1)
  RC=$?
  assert_exit "V: shared-lib trigger exits 0" 0 "$RC"
  assert_contains "V: must-rerun-all named pid-file-read.sh trigger" "$OUT" \
    "must-rerun-all trigger matched (tools/shared/process-management/pid-file-read.sh)"
  assert_contains "V: alpha ran (full fallback)" "$OUT" "PASS: [1] alpha"
  assert_contains "V: beta ran (full fallback)" "$OUT" "PASS: [1] beta"
  assert_contains "V: 2 test files (full fallback)" "$OUT" "2 test file"
  rm -rf "$VREPO"
else
  skip_case "V: git not on PATH — RERUN_ALL_TRIGGERS fallback not exercisable"
fi

# --- Case W: git-discovery `-f` guard skips index-but-absent files ------
# Under sparse-checkout a tracked *.test.sh can sit in the index but be absent
# on disk; `git ls-files` still lists it. The `-f` guard in
# _exclude_discovery_noise drops it so the replay loop never `bash <missing>`
# and a sparse tree never produces spurious failures. Simulate by committing a
# test then plain-`rm` (NOT `git rm`) — index keeps it, disk loses it. Without
# the guard this run would `bash absent.test.sh` → exit 127, FAIL.
if command -v git >/dev/null 2>&1; then
  WREPO="$TEST_TMPDIR/w-repo"
  rm -rf "$WREPO"
  mkdir -p "$WREPO"
  (
    cd "$WREPO" || exit 1
    git init -q
    git config user.email 'selftest@example.invalid'
    git config user.name 'selftest'
    printf '#!/usr/bin/env bash\nprintf "PASS: [1] present\\n"\nexit 0\n' >present.test.sh
    printf '#!/usr/bin/env bash\nprintf "PASS: [1] absent\\n"\nexit 0\n' >absent.test.sh
    git add -A
    git commit --quiet -m init
    rm absent.test.sh
  )
  OUT=$(bash "$RUNNER" "$WREPO" 2>&1)
  RC=$?
  assert_exit "W: index-but-absent file does not fail the run" 0 "$RC"
  assert_contains "W: present test still ran" "$OUT" "PASS: [1] present"
  assert_not_contains "W: absent test not enqueued" "$OUT" "absent.test.sh"
  assert_not_contains "W: no missing-file bash error" "$OUT" "No such file"
  assert_contains "W: 1 test file (absent skipped)" "$OUT" "1 test file"
  rm -rf "$WREPO"
else
  skip_case "W: git not on PATH — git-discovery -f guard not exercisable"
fi

report
