#!/usr/bin/env bash
# Regression tests for tools/cloud-setup/codex-cloud-maintenance.sh.
#
# Strategy mirrors codex-cloud-setup.test.sh: copy script into a fake repo
# tree with a stubbed bootstrap.sh sibling so $ROOT resolves there.
#
# Coverage:
#   - bootstrap.sh invoked with --quiet
#   - MEDIA_TOOLS_REQUIRED=false propagated
#   - bootstrap.sh failure → script propagates non-zero exit

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$SCRIPT_DIR/codex-cloud-maintenance.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

make_fixture() {
  local repo="$1" marker="$2" bootstrap_exit="${3:-0}"
  mkdir -p "$repo/tools/cloud-setup"
  cp "$SCRIPT_SRC" "$repo/tools/cloud-setup/codex-cloud-maintenance.sh"

  cat >"$repo/tools/bootstrap.sh" <<EOF
#!/usr/bin/env bash
printf 'BOOTSTRAP MEDIA_TOOLS_REQUIRED=%s args=%s\n' \
  "\${MEDIA_TOOLS_REQUIRED:-unset}" "\$*" >>"$marker"
exit $bootstrap_exit
EOF
  chmod +x "$repo/tools/bootstrap.sh" 2>/dev/null || true
}

# --- Case 1: invocation → bootstrap.sh --quiet, MEDIA_TOOLS_REQUIRED=false ---
REPO_A="$TEST_TMPDIR/repo-a"
MARKER_A="$TEST_TMPDIR/marker-a.txt"
make_fixture "$REPO_A" "$MARKER_A" 0

bash "$REPO_A/tools/cloud-setup/codex-cloud-maintenance.sh" >/dev/null 2>&1
RC=$?
assert_exit "happy path → exit 0" 0 "$RC"
LOG=$(cat "$MARKER_A")
assert_contains "bootstrap invoked" "$LOG" "BOOTSTRAP"
assert_contains "--quiet forwarded" "$LOG" "args=--quiet"
assert_contains "MEDIA_TOOLS_REQUIRED=false propagated" "$LOG" "MEDIA_TOOLS_REQUIRED=false"

# --- Case 2: bootstrap failure → script propagates exit ---
REPO_B="$TEST_TMPDIR/repo-b"
MARKER_B="$TEST_TMPDIR/marker-b.txt"
make_fixture "$REPO_B" "$MARKER_B" 3

bash "$REPO_B/tools/cloud-setup/codex-cloud-maintenance.sh" >/dev/null 2>&1
RC=$?
assert_exit "bootstrap fail → script propagates non-zero" 3 "$RC"

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
