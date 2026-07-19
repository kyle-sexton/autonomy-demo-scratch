# Git / globstar discovery for *.test.sh — sourced by run.sh, not executed directly.
# shellcheck disable=SC2034  # TESTS populated when sourced by run.sh

# Scrub inherited git-hook environment before discovery or dispatch. When the
# suite runs from a git hook (the pre-push shell-test-walltime lane), git
# exports GIT_DIR / GIT_COMMON_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / ... into
# the hook process, and lefthook + this runner + the xargs workers all inherit
# them. Those vars OVERRIDE `git -C <fixture>` and even `git init` (a leaked
# GIT_DIR makes `git init <dir>` operate on the env repo instead of creating
# <dir>/.git), so every test fixture's git ops silently retarget the REAL repo —
# creating worktrees in the real hub and clobbering refs/remotes/origin/main via
# fixture `git update-ref`. Unsetting here, the single chokepoint every test
# passes through, restores directory-based resolution from each fixture's own
# path. Discovery below also benefits: it resolves by CWD (= ROOT_DIR), never a
# leaked GIT_DIR. Normal `bash tools/run-shell-tests.sh` runs carry none of these,
# so the unset is a no-op there.
scrub_git_hook_env() {
  unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_NAMESPACE GIT_PREFIX GIT_QUARANTINE_PATH
}

# Drop discovery noise — paths the suite must never run. Shared by the git
# fast path and the globstar fallback so the exclusion set is single-sourced.
# Reads candidate paths on stdin, emits the kept ones on stdout. Also drops
# paths absent from the working tree: `git ls-files` lists index entries that
# a sparse checkout may not have materialized on disk, and the replay loop
# would `bash <missing-path>` → spurious failure. The `-f` guard mirrors the
# --changed-since deletion guard below; it is a no-op for the globstar path
# (nullglob only ever emits existing files).
_exclude_discovery_noise() {
  local t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    [[ -f "$t" ]] || continue
    case "$t" in
      node_modules/* | */node_modules/* | \
        .git/* | */.git/* | \
        .venv/* | */.venv/* | \
        */bin/* | */obj/* | \
        sandboxes/*) continue ;;
    esac
    printf '%s\n' "$t"
  done
}

# Discover tests, filter, and stash in TESTS[] preserving sort order so the
# deterministic replay below matches discovery order.
#
# Fast path: when ROOT_DIR is a git work-tree root, enumerate via `git ls-files`
# (tracked) + `git ls-files --others --exclude-standard` (untracked, not
# ignored). git reads its index instead of walking the tree, so it never
# descends into node_modules/ or other large dirs the way a dotglob globstar
# does — a cold-cache globstar walk of those trees cost minutes on Windows.
# Falls back to the globstar when ROOT_DIR is NOT a work-tree root: the self
# test invokes the runner against mktemp fixture dirs that are not git repos.
# Kill switch: BASH_TEST_GIT_DISCOVERY_ENABLED=false forces the globstar path.
discover_tests() {
  TESTS=()
  local use_git_discovery=""
  if [[ "${BASH_TEST_GIT_DISCOVERY_ENABLED:-true}" == "true" ]] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [[ -z "$(git rev-parse --show-prefix 2>/dev/null)" ]]; then
    # Empty show-prefix ⇒ CWD (= ROOT_DIR, cd'd above) is the work-tree root, so
    # git ls-files paths are ROOT_DIR-relative; from a subdir they would carry a
    # prefix and break the `bash "$t"` replay, so only the root qualifies.
    use_git_discovery=1
  fi

  if [[ -n "$use_git_discovery" ]]; then
    mapfile -t TESTS < <(
      {
        git ls-files -- '*.test.sh'
        git ls-files --others --exclude-standard -- '*.test.sh'
      } | LC_ALL=C sort -u | _exclude_discovery_noise
    )
  else
    mapfile -t TESTS < <(printf '%s\n' **/*.test.sh | _exclude_discovery_noise)
  fi
}
