#!/usr/bin/env bash
# Black-box tests for tools/shared/nuget-audit/package-scan.sh.
# Sources the lib; stubs `dotnet` via a fake binary to assert the scan helpers
# pass the right flags + thread the dotnet binary, and exercises the
# NUGET_AUDIT_FLATTEN_JQ fragment against a rich fixture.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=package-scan.sh
source "$SCRIPT_DIR/package-scan.sh"

# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

if ! command -v jq >/dev/null 2>&1; then
  skip_suite "jq not installed locally — run in CI for full coverage."
fi

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Fake dotnet: records its args to $2, prints the canned JSON in $3.
make_fake_dotnet() {
  local bin="$1" args_file="$2" canned="$3"
  cat >"$bin" <<EOF
#!/usr/bin/env bash
printf '%s' "\$*" >"$args_file"
printf '%s' '$canned'
EOF
  chmod +x "$bin"
}

# Rich fixture: same id in two projects, topLevel+transitive mix, an empty
# frameworks project (mirrors the byte-preservation golden fixture).
FIXTURE='{"version":1,"projects":[{"path":"/r/Alpha.csproj","frameworks":[{"topLevelPackages":[{"id":"DupPkg","resolvedVersion":"1.0.0"}],"transitivePackages":[{"id":"TransPkg","resolvedVersion":"3.0.0"}]}]},{"path":"/r/Beta.csproj","frameworks":[{"topLevelPackages":[{"id":"DupPkg","resolvedVersion":"1.0.0"}]}]},{"path":"/r/Empty.csproj","frameworks":[]}]}'

FAKE="$TEST_TMPDIR/dotnet"
ARGS="$TEST_TMPDIR/args"

# --- scan_vulnerable: flags + stdout + dotnet_bin threading ---
make_fake_dotnet "$FAKE" "$ARGS" "$FIXTURE"
out=$(nuget_audit::scan_vulnerable "Medley.slnx" "" "$FAKE")
assert_eq "scan_vulnerable emits dotnet stdout verbatim" "$FIXTURE" "$out"
args=$(cat "$ARGS")
assert_contains "scan_vulnerable passes --vulnerable" "$args" "--vulnerable"
assert_contains "scan_vulnerable passes --include-transitive" "$args" "--include-transitive"
assert_contains "scan_vulnerable passes --format json" "$args" "--format json"
assert_contains "scan_vulnerable passes the sln arg" "$args" "Medley.slnx"

# --- scan_deprecated: --deprecated, no --vulnerable ---
make_fake_dotnet "$FAKE" "$ARGS" "$FIXTURE"
out=$(nuget_audit::scan_deprecated "Medley.slnx" "$FAKE")
assert_eq "scan_deprecated emits dotnet stdout verbatim" "$FIXTURE" "$out"
args=$(cat "$ARGS")
assert_contains "scan_deprecated passes --deprecated" "$args" "--deprecated"
assert_not_contains "scan_deprecated omits --vulnerable" "$args" "--vulnerable"

# --- timeout wrapping: dotnet still runs when timeout_secs supplied ---
if command -v timeout >/dev/null 2>&1; then
  make_fake_dotnet "$FAKE" "$ARGS" "$FIXTURE"
  out=$(nuget_audit::scan_vulnerable "Medley.slnx" 30 "$FAKE")
  assert_eq "scan_vulnerable under timeout still emits stdout" "$FIXTURE" "$out"
else
  skip_case "timeout not on PATH — wrapping branch unexercised"
fi

# --- flatten fragment: streams augmented package objects ---
flat=$(printf '%s' "$FIXTURE" | jq -c '['"$NUGET_AUDIT_FLATTEN_JQ"']')
assert_eq "flatten counts top+transitive across projects" "3" "$(printf '%s' "$flat" | jq 'length')"
assert_eq "flatten carries project_path (project 1)" "/r/Alpha.csproj" "$(printf '%s' "$flat" | jq -r '.[0].project_path')"
assert_eq "flatten preserves top-level id" "DupPkg" "$(printf '%s' "$flat" | jq -r '.[0].id')"
assert_eq "flatten preserves transitive id" "TransPkg" "$(printf '%s' "$flat" | jq -r '.[1].id')"
assert_eq "flatten carries project_path (project 2)" "/r/Beta.csproj" "$(printf '%s' "$flat" | jq -r '.[2].project_path')"

printf '\n=== %d test case(s), %d failed ===\n' "$CASE_NUM" "$FAILED"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
