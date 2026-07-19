#!/usr/bin/env bash
# Regression tests for tools/bootstrap.sh.
#
# Black-box: run bootstrap.sh --check-only against fake repo roots and assert
# on stdout shape + exit code. The production file probes real on-disk state,
# so these tests isolate the Playwright-browser check by pointing
# PLAYWRIGHT_BROWSERS_PATH at a per-case tmp dir (empty for the RED case,
# populated for the GREEN case).
#
# Run: bash tools/bootstrap.test.sh
# Or:  bash tools/run-shell-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/bootstrap.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Build a fake repo root with a minimal .claude/skills/course-digest/extraction layout.
# $1: target dir. Writes a package.json that references playwright so the
# gate's "is this a playwright project" guard triggers, plus a stub
# node_modules/ so the preceding npm check doesn't mask the playwright row.
make_fake_repo() {
  local root="$1"
  mkdir -p "$root/.claude/skills/course-digest/extraction/node_modules"
  cat >"$root/.claude/skills/course-digest/extraction/package.json" <<'JSON'
{
  "name": "fake-course-extraction",
  "private": true,
  "type": "module",
  "dependencies": { "playwright": "^1.52.0" }
}
JSON
}

# Run bootstrap against a fake root with a specific browsers cache dir.
# $1 root, $2 browsers path.
run_check() {
  local root="$1" browsers="$2"
  PLAYWRIGHT_BROWSERS_PATH="$browsers" bash "$SCRIPT" --check-only "$root" 2>&1
}

# Run bootstrap with a PATH that intentionally lacks ffmpeg and magick while
# satisfying unrelated hard prerequisites. This keeps media-tool assertions
# deterministic even on developer machines that have those tools installed.
run_check_without_media_tools() {
  local root="$1" browsers="$2" media_tools_required="$3"
  local fake_bin="$TEST_TMPDIR/fake-bin-$media_tools_required"
  local bash_path dirname_path grep_path head_path pwd_path tr_path uname_path

  mkdir -p "$fake_bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/actionlint"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/check-jsonschema"
  # Cross-cutting tooling bootstrap.sh treats as mandatory — including jq, the
  # hook-layer JSON dependency. Without these stubs case F (optional media
  # tools) would fail on the mandatory checks rather than the media-tool checks
  # under test.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/typos"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/gitleaks"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/ec"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/lefthook"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/jq"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/gh"
  chmod +x "$fake_bin/actionlint" "$fake_bin/check-jsonschema" \
    "$fake_bin/typos" "$fake_bin/gitleaks" "$fake_bin/ec" \
    "$fake_bin/lefthook" "$fake_bin/jq" "$fake_bin/gh"

  # type -P resolves to external binary path only, skipping shell builtins.
  # Using `command -v` here returns the builtin name (e.g. "pwd") on systems
  # where `pwd` resolves to a shell builtin first; ln -sf then fails because
  # there is no absolute path to symlink to.
  bash_path="$(type -P bash || true)"
  dirname_path="$(type -P dirname || true)"
  grep_path="$(type -P grep || true)"
  head_path="$(type -P head || true)"
  pwd_path="$(type -P pwd || true)"
  tr_path="$(type -P tr || true)"
  uname_path="$(type -P uname || true)"

  if [[ -z "$bash_path" || -z "$dirname_path" || -z "$grep_path" ||
    -z "$head_path" || -z "$pwd_path" || -z "$tr_path" ||
    -z "$uname_path" ]]; then
    return 127
  fi
  ln -sf "$bash_path" "$fake_bin/bash"
  ln -sf "$dirname_path" "$fake_bin/dirname"
  ln -sf "$grep_path" "$fake_bin/grep"
  ln -sf "$head_path" "$fake_bin/head"
  ln -sf "$pwd_path" "$fake_bin/pwd"
  ln -sf "$tr_path" "$fake_bin/tr"
  ln -sf "$uname_path" "$fake_bin/uname"

  run_check_with_fake_bin "$fake_bin" "$root" "$browsers" "$media_tools_required"
}

run_check_with_fake_bin() {
  local fake_bin="$1" root="$2" browsers="$3" media_tools_required="$4"

  PATH="$fake_bin" \
    MEDIA_TOOLS_REQUIRED="$media_tools_required" \
    PLAYWRIGHT_BROWSERS_PATH="$browsers" \
    bash "$SCRIPT" --check-only "$root" 2>&1
}

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# --- Case A: Playwright browsers missing (RED for new check) -----------------

ROOT_A="$TEST_TMPDIR/repo-a"
BROWSERS_A="$TEST_TMPDIR/browsers-a"
make_fake_repo "$ROOT_A"
mkdir -p "$BROWSERS_A" # empty cache dir

OUT_A=$(run_check "$ROOT_A" "$BROWSERS_A" || true)

assert_contains "case A: playwright gap surfaced" "$OUT_A" "Playwright"
assert_contains "case A: install hint present" "$OUT_A" "playwright install chromium"
PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_A" assert_command_fails "case A exit code non-zero" \
  bash "$SCRIPT" --check-only "$ROOT_A"

# --- Case B: Playwright browsers present (happy path) ------------------------

ROOT_B="$TEST_TMPDIR/repo-b"
BROWSERS_B="$TEST_TMPDIR/browsers-b"
make_fake_repo "$ROOT_B"
# Fake a chromium-NNNN directory — the version suffix drifts with Playwright
# releases, so the production glob matches chromium-[0-9]* and we place one
# here to represent "browser installed".
mkdir -p "$BROWSERS_B/chromium-1208"

OUT_B=$(run_check "$ROOT_B" "$BROWSERS_B" || true)

assert_not_contains "case B: no playwright gap when chromium present" "$OUT_B" "Playwright Chromium"

# --- Case C: mode 1 (PLAYWRIGHT_BROWSERS_PATH unset → per-OS default) --------
#
# With the env var unset, the check falls through to per-OS cache defaults
# (LOCALAPPDATA on Windows, XDG_CACHE_HOME on Linux, etc.). We can't pre-
# populate the real default path without polluting the user's system, so
# we point the default at a sandboxed dir via HOME + XDG_CACHE_HOME on
# Linux and LOCALAPPDATA on Git Bash/Windows, then populate it.

ROOT_C="$TEST_TMPDIR/repo-c"
DEFAULT_C="$TEST_TMPDIR/default-c"
make_fake_repo "$ROOT_C"
mkdir -p "$DEFAULT_C/ms-playwright/chromium-1300"

# Redirect the per-OS default by overriding the env vars the script reads.
# Explicitly unset PLAYWRIGHT_BROWSERS_PATH so the else-branch runs.
OUT_C=$(
  unset PLAYWRIGHT_BROWSERS_PATH
  HOME="$DEFAULT_C" XDG_CACHE_HOME="$DEFAULT_C" LOCALAPPDATA="$DEFAULT_C" \
    bash "$SCRIPT" --check-only "$ROOT_C" 2>&1 || true
)

assert_not_contains "case C: mode 1 (unset) resolves per-OS default when populated" \
  "$OUT_C" "Playwright Chromium browser not installed"

# Mode 1 RED: default dir exists but has no chromium-[0-9]* subdir → surface gap.
DEFAULT_C_EMPTY="$TEST_TMPDIR/default-c-empty"
mkdir -p "$DEFAULT_C_EMPTY/ms-playwright"
OUT_C_RED=$(
  unset PLAYWRIGHT_BROWSERS_PATH
  HOME="$DEFAULT_C_EMPTY" XDG_CACHE_HOME="$DEFAULT_C_EMPTY" LOCALAPPDATA="$DEFAULT_C_EMPTY" \
    bash "$SCRIPT" --check-only "$ROOT_C" 2>&1 || true
)
assert_contains "case C: mode 1 (unset) surfaces gap when default has no chromium" \
  "$OUT_C_RED" "Playwright"

# --- Case D: mode 2 (PLAYWRIGHT_BROWSERS_PATH=0 → hermetic install) ---------
#
# Hermetic mode puts browsers at <project>/node_modules/playwright-core/.local-browsers.
# Build the hermetic tree under the fake repo and verify the check finds it.

ROOT_D="$TEST_TMPDIR/repo-d"
make_fake_repo "$ROOT_D"
HERMETIC_D="$ROOT_D/.claude/skills/course-digest/extraction/node_modules/playwright-core/.local-browsers"
mkdir -p "$HERMETIC_D/chromium-1310"

OUT_D=$(PLAYWRIGHT_BROWSERS_PATH=0 bash "$SCRIPT" --check-only "$ROOT_D" 2>&1 || true)
assert_not_contains "case D: mode 2 (=0 hermetic) finds chromium in node_modules" \
  "$OUT_D" "Playwright Chromium browser not installed"

# Mode 2 RED: hermetic dir exists but chromium-* is missing → surface gap.
ROOT_D_RED="$TEST_TMPDIR/repo-d-red"
make_fake_repo "$ROOT_D_RED"
mkdir -p "$ROOT_D_RED/.claude/skills/course-digest/extraction/node_modules/playwright-core/.local-browsers"

OUT_D_RED=$(PLAYWRIGHT_BROWSERS_PATH=0 bash "$SCRIPT" --check-only "$ROOT_D_RED" 2>&1 || true)
assert_contains "case D: mode 2 (=0 hermetic) surfaces gap when hermetic has no chromium" \
  "$OUT_D_RED" "Playwright"
PLAYWRIGHT_BROWSERS_PATH=0 assert_command_fails "case D: mode 2 (=0 hermetic) exit code non-zero on gap" \
  bash "$SCRIPT" --check-only "$ROOT_D_RED"

# --- Cases E+F skip on Git Bash / MSYS / Cygwin --------------------------------
#
# These cases swap PATH for a fake bin containing only symlinks to coreutils
# (bash, dirname, grep, head, pwd, tr, uname). On Linux/macOS this works because
# the linked binary self-resolves its dependencies. On Git Bash for Windows the
# bash.exe under the symlink can't load its sibling DLLs (msys-2.0.dll, ...) so
# the symlinked bash fails with "error while loading shared libraries". The
# fake-PATH technique is fundamentally Linux/macOS-only here. Skip rather than
# false-fail.
case "${OSTYPE:-}" in
  msys* | cygwin* | win32*)
    printf 'SKIP: cases E+F skipped on %s — fake-PATH technique requires non-MSYS bash\n' \
      "$OSTYPE"
    ;;
  *)
    # --- Case E: missing media tools are fatal by default --------------------

    ROOT_E="$TEST_TMPDIR/repo-e"
    BROWSERS_E="$TEST_TMPDIR/browsers-e"
    make_fake_repo "$ROOT_E"
    mkdir -p "$BROWSERS_E/chromium-1320"

    OUT_E=$(run_check_without_media_tools "$ROOT_E" "$BROWSERS_E" "true" || true)
    assert_contains "case E: default mode reports missing ffmpeg" "$OUT_E" "ffmpeg: not found on PATH"
    assert_contains "case E: default mode reports missing ImageMagick 7" "$OUT_E" "ImageMagick 7: not found on PATH"
    assert_command_fails "case E: default mode exit code non-zero for missing media tools" \
      run_check_with_fake_bin "$TEST_TMPDIR/fake-bin-true" "$ROOT_E" "$BROWSERS_E" "true"

    # --- Case F: missing media tools can be reported without failing ---------

    ROOT_F="$TEST_TMPDIR/repo-f"
    BROWSERS_F="$TEST_TMPDIR/browsers-f"
    make_fake_repo "$ROOT_F"
    mkdir -p "$BROWSERS_F/chromium-1330"

    OUT_F=$(run_check_without_media_tools "$ROOT_F" "$BROWSERS_F" "false" || true)
    assert_contains "case F: optional mode still reports missing ffmpeg" "$OUT_F" "ffmpeg: not found on PATH (optional)"
    assert_contains "case F: optional mode still reports missing ImageMagick 7" "$OUT_F" "ImageMagick 7: not found on PATH (optional)"
    run_check_with_fake_bin "$TEST_TMPDIR/fake-bin-false" "$ROOT_F" "$BROWSERS_F" "false" >/dev/null 2>&1
    assert_exit "case F: optional mode exits zero for missing media tools" "0" "$?"

    # --- Case E2: required tool present-but-below-floor emits a FAIL row ------
    # Regression: check_binary_tool_with_floor must emit ROW FAIL (not WARN) for
    # a required below-floor tool. /onboard Phase 5 degrades WARN rows to pass,
    # so a WARN here would let a stale required tool slip through onboarding.
    FLOOR_BIN="$TEST_TMPDIR/fake-bin-floor"
    mkdir -p "$FLOOR_BIN"
    for stub in actionlint check-jsonschema typos gitleaks ec lefthook magick jq; do
      printf '#!/usr/bin/env bash\nexit 0\n' >"$FLOOR_BIN/$stub"
    done
    # ffmpeg present but below the 7.1 floor (reports 4.4.1).
    printf '#!/usr/bin/env bash\necho "ffmpeg version 4.4.1"\n' >"$FLOOR_BIN/ffmpeg"
    chmod +x "$FLOOR_BIN"/*
    for util in bash dirname grep head pwd tr uname; do
      util_path="$(type -P "$util" || true)"
      [[ -n "$util_path" ]] && ln -sf "$util_path" "$FLOOR_BIN/$util"
    done
    ROOT_E2="$TEST_TMPDIR/repo-e2"
    BROWSERS_E2="$TEST_TMPDIR/browsers-e2"
    make_fake_repo "$ROOT_E2"
    mkdir -p "$BROWSERS_E2/chromium-1340"

    OUT_E2_REQ=$(PATH="$FLOOR_BIN" MEDIA_TOOLS_REQUIRED="true" \
      PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_E2" \
      bash "$SCRIPT" --check-only --report-rows "$ROOT_E2" 2>&1 || true)
    assert_contains "case E2: required below-floor ffmpeg emits FAIL row" \
      "$OUT_E2_REQ" "$(printf 'ROW\tFAIL\tffmpeg')"

    OUT_E2_OPT=$(PATH="$FLOOR_BIN" MEDIA_TOOLS_REQUIRED="false" \
      PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_E2" \
      bash "$SCRIPT" --check-only --report-rows "$ROOT_E2" 2>&1 || true)
    assert_contains "case E2: optional below-floor ffmpeg emits WARN row" \
      "$OUT_E2_OPT" "$(printf 'ROW\tWARN\tffmpeg')"
    ;;
esac

# --- Fast-path cases (Phase 3 mtime gate) -----------------------------------
# State file is now per-root: last-success-<cksum-of-ROOT>.ts

# Helper: compute state filename for a given root (mirrors bootstrap.sh logic).
state_file_for_root() {
  local root="$1" state_dir="$2"
  local hash
  hash=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
  printf '%s/last-success-%s.ts' "$state_dir" "$hash"
}

# Case G: --check-only bypasses fast-path even with newer state file
HOME_G="$TEST_TMPDIR/case-g"
STATE_DIR_G="$HOME_G/.cache/medley-bootstrap"
mkdir -p "$STATE_DIR_G"
ROOT_G="$TEST_TMPDIR/repo-g"
mkdir -p "$ROOT_G"
touch -t 200001010000 "$ROOT_G/package.json"
touch "$(state_file_for_root "$ROOT_G" "$STATE_DIR_G")"
OUT_G=$(HOME="$HOME_G" XDG_CACHE_HOME="$HOME_G/.cache" LOCALAPPDATA="" \
  bash "$SCRIPT" --check-only --quiet "$ROOT_G" 2>&1 || true)
assert_not_contains "case G: --check-only bypasses fast-path" "$OUT_G" "cached OK"

# Case H: --report-rows bypasses fast-path
HOME_H="$TEST_TMPDIR/case-h"
STATE_DIR_H="$HOME_H/.cache/medley-bootstrap"
mkdir -p "$STATE_DIR_H"
ROOT_H="$TEST_TMPDIR/repo-h"
mkdir -p "$ROOT_H"
touch -t 200001010000 "$ROOT_H/package.json"
touch "$(state_file_for_root "$ROOT_H" "$STATE_DIR_H")"
OUT_H=$(HOME="$HOME_H" XDG_CACHE_HOME="$HOME_H/.cache" LOCALAPPDATA="" \
  bash "$SCRIPT" --report-rows "$ROOT_H" 2>&1 || true)
assert_not_contains "case H: --report-rows bypasses fast-path" "$OUT_H" "cached OK"

# Case I: cold start (no state file) runs full scan
HOME_I="$TEST_TMPDIR/case-i"
mkdir -p "$HOME_I/.cache"
ROOT_I="$TEST_TMPDIR/repo-i"
mkdir -p "$ROOT_I"
OUT_I=$(HOME="$HOME_I" XDG_CACHE_HOME="$HOME_I/.cache" LOCALAPPDATA="" \
  bash "$SCRIPT" --quiet "$ROOT_I" 2>&1 || true)
assert_not_contains "case I: cold start runs full scan" "$OUT_I" "cached OK"

# Case J: fast-path fires when state newer than manifests AND bootstrap.sh
HOME_J="$TEST_TMPDIR/case-j"
STATE_DIR_J="$HOME_J/.cache/medley-bootstrap"
mkdir -p "$STATE_DIR_J"
ROOT_J="$TEST_TMPDIR/repo-j"
mkdir -p "$ROOT_J"
touch -t 200001010000 "$ROOT_J/package.json"
STATE_FILE_J="$(state_file_for_root "$ROOT_J" "$STATE_DIR_J")"
touch -t 209901010000 "$STATE_FILE_J" 2>/dev/null || touch "$STATE_FILE_J"
if [[ "$SCRIPT" -nt "$STATE_FILE_J" ]]; then
  skip_case "case J: bootstrap.sh newer than synthetic state — uncontrollable in CI"
else
  # Drop --quiet so fast-path's "cached OK" print fires (QUIET=true suppresses it).
  OUT_J=$(HOME="$HOME_J" XDG_CACHE_HOME="$HOME_J/.cache" LOCALAPPDATA="" \
    bash "$SCRIPT" "$ROOT_J" 2>&1 || true)
  exit_j=$?
  assert_contains "case J: fast-path emits cached OK" "$OUT_J" "cached OK"
  assert_exit "case J: fast-path exits 0" "0" "$exit_j"
fi

# --- Auto-discovery cases ----------------------------------------------------

# Case K: auto-discovers Node MCP server under mcp-servers/
ROOT_K="$TEST_TMPDIR/repo-k"
mkdir -p "$ROOT_K/mcp-servers/test-server/node"
cat >"$ROOT_K/mcp-servers/test-server/node/package.json" <<'JSON'
{ "name": "test-mcp", "private": true }
JSON
OUT_K=$(bash "$SCRIPT" --check-only --report-rows "$ROOT_K" 2>&1 || true)
assert_contains "case K: auto-discovers Node MCP server" "$OUT_K" "test-server-node-mcp"

# Case L: per-root cache key derives distinct filenames for different roots
# (Verify the hash function produces different names — actual state file
# persistence requires HAS_FAILURE=false which needs a full git repo.)
HOME_L="$TEST_TMPDIR/case-l"
ROOT_L1="$TEST_TMPDIR/repo-l1"
ROOT_L2="$TEST_TMPDIR/repo-l2"
STATE_FILE_L1="$(state_file_for_root "$ROOT_L1" "$HOME_L")"
STATE_FILE_L2="$(state_file_for_root "$ROOT_L2" "$HOME_L")"
if [[ "$STATE_FILE_L1" != "$STATE_FILE_L2" ]]; then
  pass "case L: distinct state filenames per root"
else
  fail "case L: distinct state filenames per root" "different paths" "same path: $STATE_FILE_L1"
fi

# Case M: mcp-servers/ absent — no errors, clean exit
ROOT_M="$TEST_TMPDIR/repo-m"
mkdir -p "$ROOT_M"
OUT_M=$(bash "$SCRIPT" --check-only --report-rows "$ROOT_M" 2>&1 || true)
assert_not_contains "case M: no errors when mcp-servers/ absent" "$OUT_M" "Error"

# Case N: jq is a declared prerequisite (regression — closes the silent
# hook-degradation gap where jq-absent makes branch-protection.sh fail open).
# Asserts jq is CHECKED via --report-rows; robust to jq's presence on the
# runner (the row is emitted PASS-or-FAIL either way, both contain the jq NAME
# field delimited by tabs).
ROOT_N="$TEST_TMPDIR/repo-n"
mkdir -p "$ROOT_N"
OUT_N=$(bash "$SCRIPT" --check-only --report-rows "$ROOT_N" 2>&1 || true)
assert_contains "case N: jq is a declared prerequisite" "$OUT_N" "$(printf '\tjq\t')"

# --- Report ------------------------------------------------------------------

if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d checks passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
