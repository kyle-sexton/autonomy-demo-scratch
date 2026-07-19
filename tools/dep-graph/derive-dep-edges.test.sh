#!/usr/bin/env bash
# Regression tests for tools/dep-graph/derive-dep-edges.sh.
#
# Each case builds a throwaway git repo (mkrepo) with known tracked files, runs
# the script with cwd inside that repo (the script resolves its scan root via
# `git rev-parse --show-toplevel`), and asserts the emitted TSV edges. Fixtures
# are deterministic — no dependency on the live repo's tracked tree.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/derive-dep-edges.sh"

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

FIXTURE_REPOS=()
cleanup() {
  local r
  for r in "${FIXTURE_REPOS[@]:-}"; do
    [[ -n "$r" ]] && rm -rf "$r"
  done
}
trap cleanup EXIT

# Create a throwaway git repo and echo its path.
mkrepo() {
  local repo
  repo="$(mktemp -d)"
  git init --quiet "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "test"
  FIXTURE_REPOS+=("$repo")
  printf '%s' "$repo"
}

# Write a tracked file into a fixture repo. `git ls-files` lists staged files,
# so staging (no commit) is enough for the script to see them.
add_file() {
  local repo="$1" rel="$2" content="$3"
  (
    cd "$repo" || exit 1
    mkdir -p "$(dirname "$rel")"
    printf '%s\n' "$content" >"$rel"
    git add "$rel"
  )
}

# Run the script with cwd inside the fixture repo; pass through extra flags.
run() {
  (cd "$1" && bash "$SCRIPT" "${@:2}")
}

edge() { printf '%s\t%s\t%s' "$1" "$2" "$3"; }

# --- Contract: --help exits 0 with non-empty usage naming the tool ---

help_out="$(bash "$SCRIPT" --help 2>&1)"
help_code=$?
assert_exit "--help exits 0" 0 "$help_code"
assert_contains "--help names the tool" "$help_out" "derive-dep-edges"

# --- Contract: unknown arg → exit 2 ---

bash "$SCRIPT" --bogus-arg >/dev/null 2>&1
bogus_code=$?
assert_exit "unknown arg exits 2" 2 "$bogus_code"

# --- Contract: a flag missing its value is a usage error (exit 2) ---

bash "$SCRIPT" --target >/dev/null 2>&1
missing_code=$?
assert_exit "--target with no value exits 2" 2 "$missing_code"

# --- source kind: shell `source`/`.` statement ---

r="$(mkrepo)"
add_file "$r" "tools/example/foo.sh" "echo hi"
add_file "$r" "a.sh" 'source "tools/example/foo.sh"'
out="$(run "$r")"
assert_contains "source edge emitted" "$out" "$(edge "a.sh" "source" "tools/example/foo.sh")"

# --- exec kind: `bash <path>` invocation ---

r="$(mkrepo)"
add_file "$r" "tools/bar.sh" "echo hi"
add_file "$r" "run.sh" 'bash tools/bar.sh'
out="$(run "$r")"
assert_contains "exec edge emitted" "$out" "$(edge "run.sh" "exec" "tools/bar.sh")"

# --- exec kind in YAML: `run: bash <path>` (registry-pointer form) ---

r="$(mkrepo)"
add_file "$r" "tools/gate.sh" "echo hi"
add_file "$r" "lefthook.yml" "    run: bash tools/gate.sh"
out="$(run "$r")"
assert_contains "yaml exec edge emitted" "$out" "$(edge "lefthook.yml" "exec" "tools/gate.sh")"

# --- cite kind: path literal in markdown ---

r="$(mkrepo)"
add_file "$r" "tools/example/baz.sh" "echo hi"
add_file "$r" "doc.md" "See tools/example/baz.sh for details."
out="$(run "$r")"
assert_contains "cite edge emitted" "$out" "$(edge "doc.md" "cite" "tools/example/baz.sh")"

# --- cite kind: directory literal with trailing slash stripped, validated ---
# against the dir-ancestor set (not just exact tracked file paths) ---

r="$(mkrepo)"
add_file "$r" "tools/shared/eol/normalize.sh" "echo hi"
add_file "$r" "doc.md" "Moved tools/shared/eol/ to shared tier."
out="$(run "$r")"
assert_contains "dir cite (trailing slash stripped)" "$out" "$(edge "doc.md" "cite" "tools/shared/eol")"

# --- per-cite: two valid paths on one line → two edges ---

r="$(mkrepo)"
add_file "$r" "tools/example/a.sh" "echo a"
add_file "$r" "tools/example/b.sh" "echo b"
add_file "$r" "doc.md" "see tools/example/a.sh and tools/example/b.sh together"
out="$(run "$r")"
assert_contains "multi-cite first token" "$out" "$(edge "doc.md" "cite" "tools/example/a.sh")"
assert_contains "multi-cite second token" "$out" "$(edge "doc.md" "cite" "tools/example/b.sh")"

# --- noise rejection: a path literal that is not a tracked file/dir is dropped ---

r="$(mkrepo)"
add_file "$r" "tools/real.sh" "echo hi"
add_file "$r" "doc.md" "fake ref to tools/ghost/missing.sh here"
out="$(run "$r")"
assert_not_contains "untracked target dropped" "$out" "tools/ghost/missing.sh"

# --- --target <prefix>: keep edges whose target starts with the prefix ---

r="$(mkrepo)"
add_file "$r" "tools/example/x.sh" "echo x"
add_file "$r" "tools/other/y.sh" "echo y"
add_file "$r" "doc.md" "see tools/example/x.sh and tools/other/y.sh"
out="$(run "$r" --target tools/example/)"
assert_contains "--target keeps matching target" "$out" "tools/example/x.sh"
assert_not_contains "--target drops non-matching target" "$out" "tools/other/y.sh"

# --- --from <prefix>: keep edges whose source starts with the prefix ---

r="$(mkrepo)"
add_file "$r" "tools/example/z.sh" "echo z"
add_file "$r" "docs/keep.md" "see tools/example/z.sh"
add_file "$r" "docs/drop.md" "see tools/example/z.sh"
out="$(run "$r" --from docs/keep.md)"
assert_contains "--from keeps matching source" "$out" "docs/keep.md"
assert_not_contains "--from drops non-matching source" "$out" "docs/drop.md"

# --- empty result → exit 0, empty stdout ---

r="$(mkrepo)"
add_file "$r" "README.md" "just prose, no repo paths here"
out="$(run "$r")"
empty_code=$?
assert_exit "no edges → exit 0" 0 "$empty_code"
assert_silent "no edges → empty stdout" "$out"

# --- contract scope: a path in a shell COMMENT is not a cite edge ---
# (cite kind is scoped to md/yml/yaml/json/toml, never shell bodies) ---

r="$(mkrepo)"
add_file "$r" "tools/example/c.sh" "echo c"
add_file "$r" "script.sh" "# see tools/example/c.sh for the helper"
out="$(run "$r")"
assert_silent "shell comment path is not an edge" "$out"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
