# Shared helpers for the run-skill-comparison.sh test shards — NOT
# *.test.sh-named, so the runner ignores it. Sourced by:
#   run-skill-comparison.test.sh            (contract + dry-run cycle)
#   run-skill-comparison-worktree-safety.test.sh
#   run-skill-comparison-failure-paths.test.sh
# Each shard owns its own TEST_TMPDIR + cleanup trap + counters.
set -uo pipefail

# Standalone invocation has no runner scrub — drop any inherited git env that
# would redirect the fixture repos at the real repo.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HELPER_DIR/run-skill-comparison.sh"

: "${FAILED:=0}"
: "${CASE_NUM:=0}"

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Hub safety guard: fixture repos are isolated, but the driver must not leave
# skill-comparison registrations in the real hub or drop pre-existing hub
# worktrees. Count-only checks flake under parallel xargs (sibling shards may
# add hub worktrees); preserve the snapshot path set instead.
real_hub_wt_paths() {
  git -C "$HELPER_DIR" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { print $2 }' | sort
}

REAL_HUB_WT_SNAPSHOT="$(real_hub_wt_paths)"

assert_real_hub_unchanged() {
  local path now
  now="$(real_hub_wt_paths)"
  if git -C "$HELPER_DIR" worktree list 2>/dev/null | grep -q skill-comparison; then
    fail "real-hub has no skill-comparison worktrees" "none" \
      "$(git -C "$HELPER_DIR" worktree list | grep skill-comparison || true)"
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! grep -Fxq "$path" <<<"$now"; then
      fail "real-hub worktree preserved" "$path" "removed during shard"
    fi
  done <<<"$REAL_HUB_WT_SNAPSHOT"
}

# make_prompt <path> — fixture prompt file
make_prompt() {
  printf 'Run the comparison fixture prompt.\n' >"$1"
}

# make_fixture <dir> — temp repo with a committed skill.md
make_fixture() {
  make_repo "$1"
  printf 'original body line\n' >"$1/skill.md"
  git -C "$1" add skill.md
  git -C "$1" commit -qm "add skill body"
}

# make_patch <fixture> <patch-path> — text-anchored diff relaxing skill.md
make_patch() {
  printf 'relaxed body line\n' >"$1/skill.md"
  git -C "$1" diff >"$2"
  git -C "$1" checkout -q -- skill.md
}

# run_driver <fixture> <wt-tmpdir> <args...> — cwd inside fixture, worktree
# tmpdir redirected under the shard tmpdir so leaks are impossible.
run_driver() {
  local fixture="$1" wt_tmp="$2"
  shift 2
  mkdir -p "$wt_tmp"
  (cd "$fixture" && TMPDIR="$wt_tmp" bash "$DRIVER" "$@") 2>&1
}

report() {
  [[ $FAILED -eq 0 ]] || exit 1
  exit 0
}
