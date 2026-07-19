#!/usr/bin/env bash
# Tests for emit-ci-run-facts.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

EMIT="$SCRIPT_DIR/emit-ci-run-facts.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILED=0

assert_exit "--help exits 0" 0 "$(
  bash "$EMIT" --help >/dev/null 2>&1
  echo $?
)"

fake_bin="$TEST_TMPDIR/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [[ "$*" == *"repo view"* ]]; then
  printf 'melodic/medley\n'
  exit 0
fi
if [[ "$*" == *"actions/runs/12345/jobs"* ]]; then
  printf '{"jobs":[{"name":"ci","conclusion":"success","steps":[{"conclusion":"success"},{"conclusion":"skipped"}]}]}\n'
  exit 0
fi
if [[ "$*" == *"actions/runs/12345/timing"* ]]; then
  printf '{"billable_ms":42000}\n'
  exit 0
fi
if [[ "$*" == *"actions/runs/12345"* ]]; then
  printf '{"conclusion":"success","status":"completed"}\n'
  exit 0
fi
exit 1
FAKEGH
chmod +x "$fake_bin/gh"

out="$(PATH="$fake_bin:$PATH" bash "$EMIT" 12345)"
assert_contains "run id" "$out" "Run id: 12345"
assert_contains "repository" "$out" "Repository: melodic/medley"
assert_contains "job line" "$out" "Job: ci"
assert_contains "jobs count" "$out" "Jobs count: 1"
assert_contains "timing" "$out" "Timing billable ms: 42000"
assert_contains "api available" "$out" "GitHub API: available"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: emit-ci-run-facts.sh tests passed"
