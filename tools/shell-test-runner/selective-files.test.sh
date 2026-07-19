#!/usr/bin/env bash
# Regression tests for tools/run-shell-tests.sh — selective --files dispatch + TEST_REPO_ROOT propagation + build-server env isolation.
# Shares fixture/runner helpers via test-helpers.sh (sibling).
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"

# --- Case N: selective dispatch (--files explicit list) ----------------
# A1 round-4: --files <path>... accepts repeated test paths and runs only
# those. Paths are interpreted relative to the runner's ROOT_DIR.
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "n1-foo" $'#!/usr/bin/env bash\nprintf "PASS: [1] foo ran\\n"\nexit 0'
make_fixture "n1-bar" $'#!/usr/bin/env bash\nprintf "PASS: [1] bar ran\\n"\nexit 0'
make_fixture "n1-baz" $'#!/usr/bin/env bash\nprintf "PASS: [1] baz ran\\n"\nexit 0'

# Positional dir comes FIRST; --files is variadic to end of argv.
# N1: single --files arg runs only that file
OUT=$(bash "$RUNNER" "$TEST_TMPDIR" --files "$TEST_TMPDIR/n1-foo.test.sh" 2>&1)
RC=$?
assert_exit "N1: --files single exits 0" 0 "$RC"
assert_contains "N1: foo ran" "$OUT" "foo ran"
assert_not_contains "N1: bar NOT run" "$OUT" "bar ran"
assert_not_contains "N1: baz NOT run" "$OUT" "baz ran"
assert_contains "N1: summary 1 test file" "$OUT" "1 test file"

# N2: multiple --files args
OUT=$(bash "$RUNNER" "$TEST_TMPDIR" --files "$TEST_TMPDIR/n1-foo.test.sh" "$TEST_TMPDIR/n1-baz.test.sh" 2>&1)
RC=$?
assert_exit "N2: --files multi exits 0" 0 "$RC"
assert_contains "N2: foo ran" "$OUT" "foo ran"
assert_contains "N2: baz ran" "$OUT" "baz ran"
assert_not_contains "N2: bar NOT run" "$OUT" "bar ran"
assert_contains "N2: summary 2 test files" "$OUT" "2 test file"

# --- Case P: TEST_REPO_ROOT sourced from ROOT_DIR ----------------------
# `bash tools/run-shell-tests.sh <other-dir>` must export TEST_REPO_ROOT
# pointing at <other-dir>, not at the runner's own repo. Child tests rely
# on TEST_REPO_ROOT to find `tests/shell/lib.sh` — wrong root reads the
# wrong lib.
rm -rf "$TEST_TMPDIR"/p-repo
mkdir -p "$TEST_TMPDIR"/p-repo/tests/shell
cat >"$TEST_TMPDIR"/p-repo/tests/shell/lib.sh <<'LIB'
#!/usr/bin/env bash
# minimal lib stand-in for fixture
LIB
# Test file echoes its resolved TEST_REPO_ROOT so we can assert on it.
cat >"$TEST_TMPDIR"/p-repo/probe.test.sh <<'F'
#!/usr/bin/env bash
printf "PASS: [1] TEST_REPO_ROOT=%s\n" "${TEST_REPO_ROOT:-UNSET}"
exit 0
F

OUT=$(bash "$RUNNER" "$TEST_TMPDIR"/p-repo 2>&1)
RC=$?
assert_exit "P1: positional ROOT_DIR exits 0" 0 "$RC"
assert_contains "P1: TEST_REPO_ROOT points at ROOT_DIR" "$OUT" "TEST_REPO_ROOT=$TEST_TMPDIR/p-repo"

# --- Case R: build-server isolation (F3) env exported to tests ---------
# The runner must export MSBUILDDISABLENODEREUSE=1 and
# DOTNET_CLI_USE_MSBUILD_SERVER=0 so dotnet-invoking child tests inherit them
# and leave no persistent MSBuild worker nodes behind.
rm -f "$TEST_TMPDIR"/*.test.sh
make_fixture "env-probe" $'#!/usr/bin/env bash\nprintf "PASS: [1] reuse=%s server=%s\\n" "${MSBUILDDISABLENODEREUSE:-UNSET}" "${DOTNET_CLI_USE_MSBUILD_SERVER:-UNSET}"\nexit 0'

OUT=$(run_runner)
RC=$?
assert_exit "R: env-probe exits 0" 0 "$RC"
assert_contains "R: MSBUILDDISABLENODEREUSE exported =1" "$OUT" "reuse=1"
assert_contains "R: DOTNET_CLI_USE_MSBUILD_SERVER exported =0" "$OUT" "server=0"

report
