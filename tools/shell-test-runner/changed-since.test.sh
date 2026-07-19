#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — --changed-since selective dispatch (git-repo builder).
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case O: selective dispatch (--changed-since <ref>) ----------------
# Builds a fixture git repo with one base commit + a topic branch that
# touches a single test file; asserts the runner runs only the impacted
# test on `--changed-since main`.
rm -rf "$TEST_TMPDIR"/o-repo
mkdir -p "$TEST_TMPDIR"/o-repo
cd "$TEST_TMPDIR"/o-repo || exit 1
git init --quiet --initial-branch=main
git config user.email t@e
git config user.name t
git config commit.gpgsign false
mkdir -p tests/shell
cat >tests/shell/lib.sh <<'LIB'
#!/usr/bin/env bash
# minimal lib stand-in for fixture
LIB
cat >foo.test.sh <<'F'
#!/usr/bin/env bash
printf "PASS: [1] foo\n"
exit 0
F
cat >bar.test.sh <<'F'
#!/usr/bin/env bash
printf "PASS: [1] bar\n"
exit 0
F
cat >baz.sh <<'F'
#!/bin/sh
echo baz
F
cat >baz.test.sh <<'F'
#!/usr/bin/env bash
printf "PASS: [1] baz tests baz.sh\n"
exit 0
F
git add -A
git commit --quiet -m init
git checkout --quiet -b feat-test
# Modify ONLY foo.test.sh — selective should pick foo.test.sh only
echo "# touch" >>foo.test.sh
git add foo.test.sh
git commit --quiet -m touch-foo
cd - >/dev/null || exit 1

# O1: --changed-since main runs only the touched test
OUT=$(bash "$RUNNER" "$TEST_TMPDIR"/o-repo --changed-since main 2>&1)
RC=$?
assert_exit "O1: --changed-since exits 0" 0 "$RC"
assert_contains "O1: foo ran (changed)" "$OUT" "PASS: [1] foo"
assert_not_contains "O1: bar NOT run (unchanged)" "$OUT" "PASS: [1] bar"
assert_contains "O1: 1 test file" "$OUT" "1 test file"

# O2: changing baz.sh (sibling-test rule) → runs baz.test.sh
cd "$TEST_TMPDIR"/o-repo || exit 1
git checkout --quiet feat-test
echo "# touch baz.sh" >>baz.sh
git add baz.sh
git commit --quiet -m touch-baz-sh
cd - >/dev/null || exit 1
OUT=$(bash "$RUNNER" "$TEST_TMPDIR"/o-repo --changed-since main 2>&1)
RC=$?
assert_exit "O2: --changed-since sibling rule exits 0" 0 "$RC"
assert_contains "O2: foo.test.sh impacted (committed earlier)" "$OUT" "PASS: [1] foo"
assert_contains "O2: baz.test.sh impacted via sibling rule" "$OUT" "baz tests baz.sh"
assert_not_contains "O2: bar NOT impacted" "$OUT" "PASS: [1] bar"

# O3: changing tests/shell/lib.sh → must-rerun-all fallback (every test)
cd "$TEST_TMPDIR"/o-repo || exit 1
echo "# touch lib" >>tests/shell/lib.sh
git add tests/shell/lib.sh
git commit --quiet -m touch-lib
cd - >/dev/null || exit 1
OUT=$(bash "$RUNNER" "$TEST_TMPDIR"/o-repo --changed-since main 2>&1)
RC=$?
assert_exit "O3: must-rerun-all exits 0" 0 "$RC"
assert_contains "O3: must-rerun-all banner" "$OUT" "must-rerun-all"
assert_contains "O3: foo ran" "$OUT" "PASS: [1] foo"
assert_contains "O3: bar ran" "$OUT" "PASS: [1] bar"
assert_contains "O3: baz ran" "$OUT" "baz tests baz.sh"
assert_contains "O3: 3 test files" "$OUT" "3 test file"

# O4: kill switch disables selective dispatch (env override)
OUT=$(BASH_TEST_SELECTIVE_DISPATCH_ENABLED=false bash "$RUNNER" "$TEST_TMPDIR"/o-repo --changed-since main 2>&1)
RC=$?
assert_exit "O4: kill switch exits 0" 0 "$RC"
assert_contains "O4: bar ran (kill switch fell back to full)" "$OUT" "PASS: [1] bar"

# O5: --changed-since with no impacted tests → exit 0, no tests ran
cd "$TEST_TMPDIR"/o-repo || exit 1
git checkout --quiet main
git checkout --quiet -b feat-nochange
echo "# unrelated doc" >docs.md
git add docs.md
git commit --quiet -m unrelated
cd - >/dev/null || exit 1
OUT=$(bash "$RUNNER" "$TEST_TMPDIR"/o-repo --changed-since main 2>&1)
RC=$?
assert_exit "O5: no impacted tests exits 0" 0 "$RC"
assert_contains "O5: empty-impact banner" "$OUT" "No impacted *.test.sh"

# O6: invalid --changed-since ref → fail fast (exit 2), no false-green
OUT=$(bash "$RUNNER" "$TEST_TMPDIR"/o-repo --changed-since definitely-not-a-ref 2>&1)
RC=$?
assert_exit "O6: invalid ref exits 2" 2 "$RC"
assert_contains "O6: invalid-ref error message" "$OUT" "invalid or unknown ref: definitely-not-a-ref"

# O7: *.test.sh deleted between <ref>...HEAD → skipped, not enqueued
cd "$TEST_TMPDIR"/o-repo || exit 1
git checkout --quiet main
git checkout --quiet -b feat-delete-test
git rm --quiet bar.test.sh
git commit --quiet -m delete-bar-test
cd - >/dev/null || exit 1
OUT=$(bash "$RUNNER" "$TEST_TMPDIR"/o-repo --changed-since main 2>&1)
RC=$?
assert_exit "O7: deletion exits 0 (not 1 from missing-file bash)" 0 "$RC"
assert_not_contains "O7: deleted bar.test.sh not enqueued" "$OUT" "PASS: [1] bar"
assert_not_contains "O7: no missing-file bash error" "$OUT" "No such file"

report
