#!/usr/bin/env bash
# Regression tests for tools/cloud-setup/codex-cloud-setup.sh.
#
# Strategy: copy the script into an isolated fake repo tree with stubbed
# bootstrap.sh + cloud-setup/setup.sh siblings. The script computes ROOT
# via `dirname/../..` so $ROOT resolves to the fake tree, and the stubs
# intercept the real bootstrap/cloud-setup invocations.
#
# Coverage:
#   - non-root: skips system-package install, still invokes bootstrap
#   - bootstrap.sh receives MEDIA_TOOLS_REQUIRED=false in env
#   - bootstrap.sh failure → script exits non-zero (set -e propagates)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$SCRIPT_DIR/codex-cloud-setup.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Build a fake repo with stubbed tools/. Marker file records every stub
# invocation so tests can assert on what ran with which env.
make_fixture() {
  local repo="$1" marker="$2" bootstrap_exit="${3:-0}"
  mkdir -p "$repo/tools/cloud-setup"
  cp "$SCRIPT_SRC" "$repo/tools/cloud-setup/codex-cloud-setup.sh"

  cat >"$repo/tools/cloud-setup/setup.sh" <<EOF
#!/usr/bin/env bash
printf 'CLOUD_SETUP invoked\n' >>"$marker"
exit 0
EOF
  chmod +x "$repo/tools/cloud-setup/setup.sh" 2>/dev/null || true

  cat >"$repo/tools/bootstrap.sh" <<EOF
#!/usr/bin/env bash
printf 'BOOTSTRAP MEDIA_TOOLS_REQUIRED=%s args=%s\n' \
  "\${MEDIA_TOOLS_REQUIRED:-unset}" "\$*" >>"$marker"
exit $bootstrap_exit
EOF
  chmod +x "$repo/tools/bootstrap.sh" 2>/dev/null || true
}

# --- Case 1: non-root invocation skips cloud-setup, runs bootstrap ---
REPO_A="$TEST_TMPDIR/repo-a"
MARKER_A="$TEST_TMPDIR/marker-a.txt"
make_fixture "$REPO_A" "$MARKER_A" 0

bash "$REPO_A/tools/cloud-setup/codex-cloud-setup.sh" >/dev/null 2>&1
RC=$?
assert_exit "non-root → exit 0" 0 "$RC"
LOG=$(cat "$MARKER_A")
assert_contains "bootstrap invoked" "$LOG" "BOOTSTRAP"
assert_contains "MEDIA_TOOLS_REQUIRED=false passed to bootstrap" "$LOG" "MEDIA_TOOLS_REQUIRED=false"
# Non-root path skips setup.sh per the `id -u == 0` guard
if grep -q CLOUD_SETUP "$MARKER_A"; then
  fail "non-root → cloud-setup NOT invoked" "absent" "present"
else
  pass "non-root → cloud-setup NOT invoked"
fi

# --- Case 2: bootstrap.sh failure → script exits non-zero ---
REPO_B="$TEST_TMPDIR/repo-b"
MARKER_B="$TEST_TMPDIR/marker-b.txt"
make_fixture "$REPO_B" "$MARKER_B" 7

bash "$REPO_B/tools/cloud-setup/codex-cloud-setup.sh" >/dev/null 2>&1
RC=$?
assert_exit "bootstrap fail → script propagates non-zero" 7 "$RC"

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
