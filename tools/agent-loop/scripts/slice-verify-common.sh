#!/usr/bin/env bash
# Canonical slice harness verification helpers — sourced by per-slice verify-common.sh.

set -euo pipefail

slice_verify_init() {
  local script_dir="$1"
  local slug="$2"
  local out_subdir="$3"
  SLICE_VERIFY_REPO_ROOT="$(cd "$script_dir/../../.." && pwd)"
  SLICE_VERIFY_SLICE_ROOT="$SLICE_VERIFY_REPO_ROOT/.work/$slug"
  SLICE_VERIFY_OUT_DIR="$SLICE_VERIFY_REPO_ROOT/$out_subdir"
  cd "$SLICE_VERIFY_REPO_ROOT"
}

assert_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    echo "PASS: $label ($path)"
  else
    echo "FAIL: $label — missing $path" >&2
    return 1
  fi
}

assert_no_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    echo "PASS: $label (absent: $path)"
  else
    echo "FAIL: $label — unexpected $path" >&2
    return 1
  fi
}

assert_dir() {
  local path="$1"
  local label="$2"
  if [[ -d "$path" ]]; then
    echo "PASS: $label ($path)"
  else
    echo "FAIL: $label — missing dir $path" >&2
    return 1
  fi
}

assert_grep_zero() {
  local label="$1"
  shift
  local hits
  hits=$(git grep -n "$@" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    echo "FAIL: $label — grep found hits:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  echo "PASS: $label (zero hits)"
}

assert_grep_has() {
  local label="$1"
  local pattern="$2"
  shift 2
  if git grep -q "$pattern" "$@"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label — pattern not found: $pattern" >&2
    return 1
  fi
}

assert_plan_phase_done() {
  local phase="$1"
  if grep -q "### Phase ${phase}:.*\[DONE\]" "$SLICE_VERIFY_SLICE_ROOT/PLAN.md"; then
    echo "PASS: PLAN Phase $phase tagged [DONE]"
  else
    echo "FAIL: PLAN Phase $phase not [DONE]" >&2
    return 1
  fi
}

assert_phase_done_marker() {
  local phase="$1"
  assert_file "$SLICE_VERIFY_OUT_DIR/phase-${phase}.done" "phase-${phase}.done marker"
}

assert_self_check_marker() {
  local phase="$1"
  assert_file "$SLICE_VERIFY_OUT_DIR/phase-${phase}.self-check.md" "phase-${phase}.self-check.md"
}

assert_not_blocked() {
  local phase="$1"
  assert_no_file "$SLICE_VERIFY_OUT_DIR/phase-${phase}.blocked" "phase-${phase} not blocked"
}

ci_quartet() {
  local pkg_dir="$1"
  local label="$2"
  echo "== CI quartet: $label ($pkg_dir) =="
  (
    cd "$pkg_dir"
    npm ci
    npm audit --omit=dev --audit-level=high
    npm run build
    npm test
  )
  echo "PASS: CI quartet $label"
}

list_ci_has() {
  local pkg_path="$1"
  local label="$2"
  if bash tools/typescript/list-ci-packages.sh | grep -Fxq "$pkg_path"; then
    echo "PASS: list-ci-packages includes $label"
  else
    echo "FAIL: list-ci-packages missing $pkg_path" >&2
    bash tools/typescript/list-ci-packages.sh >&2
    return 1
  fi
}
