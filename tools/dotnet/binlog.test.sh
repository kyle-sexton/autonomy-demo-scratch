#!/usr/bin/env bash
# shellcheck disable=SC2154
# Regression tests for tools/binlog.sh.
#
# Coverage:
#   - invokes `dotnet build` with -bl: and -v:n flags (PATH-stub spy)
#   - passes through caller args (project/solution path, -c Release, etc.)
#   - creates artifacts/ if missing
#   - propagates dotnet exit code
#
# Uses a PATH-stub `dotnet` that records its argv to a marker file and
# either exits 0 or with the configured exit code.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/binlog.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Build a per-case PATH stub directory containing a fake `dotnet`.
make_stub() {
  local stub_dir="$1" marker="$2" exit_code="${3:-0}"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/dotnet" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$marker"
exit $exit_code
EOF
  chmod +x "$stub_dir/dotnet" 2>/dev/null || true
}

# --- Case 1: no args → dotnet build called, -bl:/-v:n flags present ---
REPO_A="$TEST_TMPDIR/repo-a"
STUB_A="$TEST_TMPDIR/stub-a"
MARKER_A="$TEST_TMPDIR/marker-a.txt"
make_repo "$REPO_A"
make_stub "$STUB_A" "$MARKER_A" 0

(cd "$REPO_A" && PATH="$STUB_A:$PATH" bash "$SCRIPT")
RC=$?
assert_exit "no args → exit 0" 0 "$RC"
assert_file_exists "stub dotnet invoked" "$MARKER_A"
ARGS=$(cat "$MARKER_A")
assert_contains "stub args include 'build'" "$ARGS" "build"
assert_contains "stub args include -bl: flag" "$ARGS" "-bl:"
assert_contains "stub args include ProjectImports=Embed" "$ARGS" "ProjectImports=Embed"
assert_contains "stub args include -v:n" "$ARGS" "-v:n"

# artifacts/ should be created (directory check — assert_file_exists is
# regular-file only). Use inline -d guard with pass/fail.
if [[ -d "$REPO_A/artifacts" ]]; then
  pass "artifacts/ created (directory)"
else
  fail "artifacts/ created" "directory exists" "absent"
fi

# --- Case 2: caller arg passed through ---
REPO_B="$TEST_TMPDIR/repo-b"
STUB_B="$TEST_TMPDIR/stub-b"
MARKER_B="$TEST_TMPDIR/marker-b.txt"
make_repo "$REPO_B"
make_stub "$STUB_B" "$MARKER_B" 0

(cd "$REPO_B" && PATH="$STUB_B:$PATH" bash "$SCRIPT" -c Release SomeProject.csproj)
RC=$?
assert_exit "with caller args → exit 0" 0 "$RC"
ARGS=$(cat "$MARKER_B")
assert_contains "caller -c Release passed through" "$ARGS" "-c Release"
assert_contains "caller project path passed through" "$ARGS" "SomeProject.csproj"

# --- Case 3: dotnet exits non-zero → script exits non-zero ---
REPO_C="$TEST_TMPDIR/repo-c"
STUB_C="$TEST_TMPDIR/stub-c"
MARKER_C="$TEST_TMPDIR/marker-c.txt"
make_repo "$REPO_C"
make_stub "$STUB_C" "$MARKER_C" 5

(cd "$REPO_C" && PATH="$STUB_C:$PATH" bash "$SCRIPT")
RC=$?
assert_exit "dotnet exits 5 → script exits 5" 5 "$RC"

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
