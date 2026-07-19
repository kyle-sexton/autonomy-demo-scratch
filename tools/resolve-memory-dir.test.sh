#!/usr/bin/env bash
# shellcheck disable=SC2154
# Regression tests for tools/resolve-memory-dir.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/resolve-memory-dir.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Recompute the project-dir slug the same way the script does, for a given repo dir.
# Tests legitimately recompute expected values; this mirrors the script's transform.
slug_of() {
  local root
  root=$(cd "$1" && (cygpath -w "$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')" 2>/dev/null \
    || git rev-parse --show-toplevel 2>/dev/null | tr -d '\r'))
  printf '%s' "$root" | sed 's/[:\\/.]/-/g'
}

# --- Case 1: --help exits 0 with non-empty usage stdout ---

OUT=$(bash "$SCRIPT" --help)
RC=$?
assert_exit "--help exits 0" 0 "$RC"
assert_contains "--help prints usage" "$OUT" "Usage:"

# --- Case 2: resolves to the planted project memory dir under a controlled HOME ---

REPO2="$TEST_TMPDIR/repo2"
make_repo "$REPO2"
HOME2="$TEST_TMPDIR/home2"
SLUG2=$(slug_of "$REPO2")
PLANTED2="$HOME2/.claude/projects/$SLUG2/memory"
mkdir -p "$PLANTED2"
printf '# Memory Index\n' >"$PLANTED2/MEMORY.md"
OUT=$(cd "$REPO2" && HOME="$HOME2" bash "$SCRIPT")
assert_eq "resolves to planted project memory dir" "$PLANTED2" "$OUT"

OUT=$(cd "$REPO2" && HOME="$HOME2" bash "$SCRIPT" --facts)
assert_contains "--facts emits SESSION_DATA_DIR" "$OUT" "SESSION_DATA_DIR:"
assert_contains "--facts emits MEMORY_DIR" "$OUT" "MEMORY_DIR: $PLANTED2"
assert_contains "--facts emits PROJECT_SLUG" "$OUT" "PROJECT_SLUG: $SLUG2"

# --- Case 3: does NOT pick a foreign project's memory dir (the original bug) ---
# Plant a second, alphabetically-earlier project memory dir under the same HOME.
# The naive glob would resolve to it; the resolver must still return THIS repo's.

FOREIGN="$HOME2/.claude/projects/AAA--foreign-project/memory"
mkdir -p "$FOREIGN"
printf '# Foreign\n' >"$FOREIGN/MEMORY.md"
OUT=$(cd "$REPO2" && HOME="$HOME2" bash "$SCRIPT")
assert_eq "ignores alphabetically-earlier foreign memory dir" "$PLANTED2" "$OUT"
assert_not_contains "output is not the foreign dir" "$OUT" "AAA--foreign-project"

# --- Case 4: fresh repo (no memory written) emits the normal-clone path, exit 0 ---

REPO4="$TEST_TMPDIR/repo4"
make_repo "$REPO4"
HOME4="$TEST_TMPDIR/home4"
SLUG4=$(slug_of "$REPO4")
OUT=$(cd "$REPO4" && HOME="$HOME4" bash "$SCRIPT")
RC=$?
assert_exit "fresh repo exits 0" 0 "$RC"
assert_eq "fresh repo emits session-data memory path" "$HOME4/.claude/projects/$SLUG4/memory" "$OUT"

# --- Case 5: dotted repo dir maps `.` to `-` in the emitted slug (dot-class regression) ---
# Other fixtures carry dots only via the mktemp template, where a script/helper
# drift cancels out through slug_of; assert the mapping on the script's own output.

REPO5="$TEST_TMPDIR/repo.dotted"
make_repo "$REPO5"
HOME5="$TEST_TMPDIR/home5"
SLUG5=$(slug_of "$REPO5")
PLANTED5="$HOME5/.claude/projects/$SLUG5/memory"
mkdir -p "$PLANTED5"
printf '# Memory Index\n' >"$PLANTED5/MEMORY.md"
OUT=$(cd "$REPO5" && HOME="$HOME5" bash "$SCRIPT" --facts)
assert_contains "dotted repo dir slugs dot to dash" "$OUT" "repo-dotted"
assert_not_contains "no literal dot survives in emitted paths" "$OUT" "repo.dotted"
assert_contains "resolves planted memory under the dot-mapped slug" "$OUT" "MEMORY_DIR: $PLANTED5"

# --- Case 6: outside a git repo exits 1 ---

OUTSIDE="$TEST_TMPDIR/not-a-repo"
mkdir -p "$OUTSIDE"
OUT=$(cd "$OUTSIDE" && bash "$SCRIPT" 2>/dev/null)
RC=$?
assert_exit "outside git repo exits 1" 1 "$RC"
assert_silent "outside git repo emits nothing on stdout" "$OUT"

[[ $FAILED -eq 0 ]] || exit 1
