#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/ensure-slice-manifest.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/ensure-slice-manifest.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# --- Case 1: --help exits 0 with non-empty stdout (skill-script-contract gate) ---

help_out="$(bash "$SCRIPT" --help)"
assert_exit "--help exit 0" 0 "$?"
assert_contains "--help prints usage" "$help_out" "ensure-slice-manifest.sh"

# --- Case 2: creates README on a named branch ---

REPO2="$TEST_TMPDIR/repo2"
make_repo "$REPO2"
(cd "$REPO2" && git checkout -q -b feat/sample-slice)
out2="$(cd "$REPO2" && bash "$SCRIPT")"
assert_exit "create exit 0" 0 "$?"
assert_file_exists "README created" "$REPO2/.work/sample-slice/README.md"
readme2="$(cat "$REPO2/.work/sample-slice/README.md")"
assert_contains "frontmatter status" "$readme2" "status: in-progress"
assert_contains "frontmatter created" "$readme2" "created: "
assert_contains "frontmatter updated" "$readme2" "updated: "
assert_contains "body H1 = Title Case prose" "$readme2" "# Sample Slice"
assert_contains "has Status section" "$readme2" "## Status"
assert_not_contains "no slug frontmatter key" "$readme2" "slug:"
assert_contains "prints manifest path" "$out2" ".work/sample-slice/README.md"

# --- Case 3: idempotent — second run does not overwrite ---

before3="$(cat "$REPO2/.work/sample-slice/README.md")"
out3="$(cd "$REPO2" && bash "$SCRIPT")"
assert_exit "idempotent exit 0" 0 "$?"
after3="$(cat "$REPO2/.work/sample-slice/README.md")"
assert_eq "idempotent: content unchanged" "$before3" "$after3"
assert_contains "idempotent: prints existing path" "$out3" ".work/sample-slice/README.md"

# --- Case 4: outside a git repo → exit 1 ---

OUTSIDE="$TEST_TMPDIR/not-a-repo"
mkdir -p "$OUTSIDE"
(cd "$OUTSIDE" && bash "$SCRIPT" >/dev/null 2>&1)
assert_exit "outside repo → exit 1" 1 "$?"

# --- Case 5: unknown argument → exit 2 ---

(bash "$SCRIPT" --bogus >/dev/null 2>&1)
assert_exit "unknown arg → exit 2" 2 "$?"

# --- Case 6: --slug overrides the branch-derived slug ---

REPO6="$TEST_TMPDIR/repo6"
make_repo "$REPO6"
(cd "$REPO6" && git checkout -q -b feat/branch-slug-ignored)
out6="$(cd "$REPO6" && bash "$SCRIPT" --slug custom-topic)"
assert_exit "--slug create exit 0" 0 "$?"
assert_file_exists "--slug README at override slug" "$REPO6/.work/custom-topic/README.md"
assert_contains "--slug prints override path" "$out6" ".work/custom-topic/README.md"
readme6="$(cat "$REPO6/.work/custom-topic/README.md")"
assert_contains "--slug body H1 from override slug" "$readme6" "# Custom Topic"

# --- Case 7: idempotent under --slug — second run does not overwrite ---

before7="$(cat "$REPO6/.work/custom-topic/README.md")"
out7="$(cd "$REPO6" && bash "$SCRIPT" --slug custom-topic)"
assert_exit "--slug idempotent exit 0" 0 "$?"
after7="$(cat "$REPO6/.work/custom-topic/README.md")"
assert_eq "--slug idempotent: content unchanged" "$before7" "$after7"
assert_contains "--slug idempotent: prints existing path" "$out7" ".work/custom-topic/README.md"

# --- Case 8: bare positional → exit 2 (this tool accepts NO positionals) ---

(cd "$REPO6" && bash "$SCRIPT" stray-positional >/dev/null 2>&1)
assert_exit "bare positional → exit 2" 2 "$?"

# --- Case 9: --slug without a value → exit 2 ---

(cd "$REPO6" && bash "$SCRIPT" --slug >/dev/null 2>&1)
assert_exit "--slug without value → exit 2" 2 "$?"

# --- Case 10: --slug glob metachars are NOT pathname-expanded into the H1 ---
# Regression for the unquoted Title-Case loop: a CWD file matching the slug glob
# corrupted the heading (slug 'zzz[qx]w' + ambient file 'zzzqw' -> 'Zzzqw' instead
# of 'Zzz[qx]w'). The fix reads into an array (no glob), so the literal survives.
# Uses [ ] (valid in Windows filenames) rather than * so the slice dir is creatable
# cross-platform; 'zzzqw' is the bait the glob 'zzz[qx]w' would expand to.
REPO10="$TEST_TMPDIR/repo10"
make_repo "$REPO10"
(cd "$REPO10" && : >'zzzqw')
out10="$(cd "$REPO10" && bash "$SCRIPT" --slug 'zzz[qx]w')"
assert_exit "--slug glob-metachar create exit 0" 0 "$?"
assert_contains "--slug prints the literal slug path" "$out10" ".work/zzz[qx]w/README.md"
readme10="$(cat "$REPO10/.work/zzz[qx]w/README.md")"
assert_contains "--slug glob metachars survive verbatim in H1" "$readme10" "# Zzz[qx]w"
assert_not_contains "H1 not corrupted by ambient CWD file" "$readme10" "Zzzqw"

# --- Case 11: --slug path-traversal is rejected → exit 2 (cannot escape .work/) ---
# Twin of scaffold-artifact's guard: `--slug ../x` would resolve slice_dir to
# "$target_root/.work/../x" and escape the slice tree. Glob metachars are NOT
# rejected (Case 10 covers their safe handling); only '/', '\', and '..' block.
REPO11="$TEST_TMPDIR/repo11"
make_repo "$REPO11"
(cd "$REPO11" && bash "$SCRIPT" --slug '../escape' >/dev/null 2>&1)
assert_exit "--slug '../escape' → exit 2" 2 "$?"
(cd "$REPO11" && bash "$SCRIPT" --slug 'a/b' >/dev/null 2>&1)
assert_exit "--slug 'a/b' separator → exit 2" 2 "$?"
(cd "$REPO11" && bash "$SCRIPT" --slug '..' >/dev/null 2>&1)
assert_exit "--slug '..' → exit 2" 2 "$?"
assert_file_absent "traversal did not create a sibling of .work/" "$REPO11/escape"

# --- Case 12: a clean kebab --slug is still accepted (no over-rejection) ---
out12="$(cd "$REPO11" && bash "$SCRIPT" --slug valid-slug-123)"
assert_exit "clean --slug exit 0" 0 "$?"
assert_contains "clean --slug prints manifest path" "$out12" ".work/valid-slug-123/README.md"
assert_file_exists "clean --slug creates manifest" "$REPO11/.work/valid-slug-123/README.md"

[[ $FAILED -eq 0 ]] || exit 1
