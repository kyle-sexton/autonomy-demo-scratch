#!/usr/bin/env bash
# shellcheck disable=SC2154
# Regression tests for tools/verification/verify-cli-flag.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/verify-cli-flag.sh"

# Per-case isolation: each test case writes cache to TEST_TMPDIR so cases
# don't bleed into the user's real cache dir at $LOCALAPPDATA/medley.
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Note: each test invocation gets a fresh `bash <script>` subprocess, so the
# verifier's cache derivation runs against the inherited env. Tests don't
# need a custom subshell wrapper — they invoke `bash "$SCRIPT" ...` directly
# and rely on the exit code. If a future case needs cache isolation, set
# `LOCALAPPDATA="$TEST_TMPDIR/case-$CASE_NUM"` inline before the call.

# --- Argument validation ---

OUT=$(bash "$SCRIPT" 2>&1)
RC=$?
assert_exit "no args → exit 3" 3 "$RC"
assert_contains "no args → usage hint" "$OUT" "expected <bin>"

OUT=$(bash "$SCRIPT" claude 2>&1)
RC=$?
assert_exit "missing flag arg → exit 3" 3 "$RC"

OUT=$(bash "$SCRIPT" claude print 2>&1) # 'print' missing -- prefix
RC=$?
assert_exit "non-flag last arg → exit 3" 3 "$RC"
assert_contains "non-flag last arg → '--' hint" "$OUT" "must start with '--'"

# --- Help flag ---

OUT=$(bash "$SCRIPT" --help 2>&1)
RC=$?
assert_exit "--help → exit 0" 0 "$RC"
assert_contains "--help → usage text" "$OUT" "Usage:"

# --- Missing binary ---

OUT=$(bash "$SCRIPT" definitely-not-a-real-binary-xyz123 --foo 2>&1)
RC=$?
assert_exit "missing binary → exit 2" 2 "$RC"
assert_contains "missing binary → message" "$OUT" "not found on PATH"

# --- Flag terminators: pipe-separated synopsis, bracket notation (deterministic) ---
# A PATH-stubbed bin whose --help mimics npm's `[-S|--save|--save-dev|...]` and
# `[--flag]` synopsis forms. Regression for flags terminated by `|` / `]` (npm,
# and any CLI using pipe-separated option synopsis) — runs without npm installed.
FAKE_DIR="$TEST_TMPDIR/fakebin"
mkdir -p "$FAKE_DIR"
cat >"$FAKE_DIR/synopsistool" <<'FAKE'
#!/usr/bin/env bash
cat <<'H'
Usage: synopsistool install [<pkg> ...]
Options:
  [-S|--save|--no-save|--save-prod|--save-dev|--save-optional]
  [--audit]
  --registry <url>
H
FAKE
chmod +x "$FAKE_DIR/synopsistool"

PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" synopsistool install --save-dev >/dev/null 2>&1
assert_exit "pipe-separated --save-dev → exit 0" 0 $?

PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" synopsistool install --audit >/dev/null 2>&1
assert_exit "bracket-terminated [--audit] → exit 0" 0 $?

PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" synopsistool install --registry >/dev/null 2>&1
assert_exit "space-terminated --registry → exit 0" 0 $?

# Prefix guard: --save-dev must NOT match the longer --save-developer query.
PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" synopsistool install --save-developer >/dev/null 2>&1
assert_exit "prefix --save-developer → exit 1 (no false match)" 1 $?

PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" synopsistool install --nonexistent >/dev/null 2>&1
assert_exit "absent --nonexistent → exit 1" 1 $?

# --- Real verification: claude binary ---
# Skip these cases if claude is not on PATH (e.g., shell-lint CI runner).

if command -v claude >/dev/null 2>&1; then

  # Known-good top-level flag.
  bash "$SCRIPT" claude --print >/dev/null 2>&1
  assert_exit "claude --print → exit 0 (real)" 0 $?

  # Known-good top-level flag with double-form.
  bash "$SCRIPT" claude --append-system-prompt >/dev/null 2>&1
  assert_exit "claude --append-system-prompt → exit 0 (real)" 0 $?

  # The 4 hallucinated flags from the original 2026-05-03 incident.
  bash "$SCRIPT" claude --max-turns >/dev/null 2>&1
  assert_exit "claude --max-turns → exit 1 (HALLUCINATED)" 1 $?

  bash "$SCRIPT" claude --init >/dev/null 2>&1
  RC=$?
  # Note: `claude` HAS an `init` SUBCOMMAND (separate from a `--init` flag).
  # The flag form `--init` must NOT exist. If this test starts failing, verify
  # via `claude --help | grep -- '--init'` — should be empty.
  assert_exit "claude --init → exit 1 (HALLUCINATED — init is a subcommand, not a flag)" 1 $RC

  bash "$SCRIPT" claude --maintenance >/dev/null 2>&1
  assert_exit "claude --maintenance → exit 1 (HALLUCINATED)" 1 $?

  bash "$SCRIPT" claude --append-system-prompt-file >/dev/null 2>&1
  assert_exit "claude --append-system-prompt-file → exit 1 (HALLUCINATED)" 1 $?

  # Equals-form flag (--output-format=json should still verify --output-format).
  bash "$SCRIPT" claude --output-format=json >/dev/null 2>&1
  assert_exit "claude --output-format=json → exit 0 (equals-form stripped)" 0 $?

else
  echo "SKIP: claude not on PATH — skipping claude-specific cases" >&2
fi

# --- Real verification: gh subcommand ---

if command -v gh >/dev/null 2>&1; then

  bash "$SCRIPT" gh pr create --body >/dev/null 2>&1
  assert_exit "gh pr create --body → exit 0 (subcommand-scoped, real)" 0 $?

  # Top-level flag NOT inherited by subcommand.
  bash "$SCRIPT" gh pr create --xyzfakeflag >/dev/null 2>&1
  assert_exit "gh pr create --xyzfakeflag → exit 1" 1 $?

else
  echo "SKIP: gh not on PATH — skipping gh-specific cases" >&2
fi

# --- Quiet mode ---

if command -v claude >/dev/null 2>&1; then
  OUT=$(bash "$SCRIPT" --quiet claude --max-turns 2>&1)
  RC=$?
  assert_exit "--quiet on hallucinated flag → exit 1" 1 "$RC"
  assert_silent "--quiet → no stderr output" "$OUT"
fi

# --- Verbose mode ---

if command -v claude >/dev/null 2>&1; then
  OUT=$(bash "$SCRIPT" --verbose claude --print 2>&1)
  RC=$?
  assert_exit "--verbose on real flag → exit 0" 0 "$RC"
  assert_contains "--verbose → prints matching line" "$OUT" "--print"
fi

# --- Verifier option parsing stops at the first positional ---
# A TARGET flag spelled --quiet/--verbose must be verified as a positional,
# not consumed as a verifier option (the old whole-argv scan returned rc 3).
PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" --quiet synopsistool install --audit >/dev/null 2>&1
assert_exit "leading --quiet still parsed as option → exit 0" 0 $?
PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" --quiet synopsistool install --verbose >/dev/null 2>&1
assert_exit "target --verbose verified, not consumed (absent → 1)" 1 $?
PATH="$FAKE_DIR:$PATH" LOCALAPPDATA="$TEST_TMPDIR/syn-cache" XDG_CACHE_HOME="$TEST_TMPDIR/syn-cache" \
  bash "$SCRIPT" --quiet synopsistool install --quiet >/dev/null 2>&1
assert_exit "target --quiet verified, not consumed (absent → 1)" 1 $?

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
