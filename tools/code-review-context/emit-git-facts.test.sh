#!/usr/bin/env bash
# Regression tests for tools/code-review-context/emit-git-facts.sh.
#
# Locks the byte-identity + graceful-degradation contract the /quality-gate
# (and future /code-review-fanout) rewire depends on: the nine labeled facts,
# cwd-invariance, non-repo / gh-unavailable degradation, LF-cleanliness, the
# security / layer-boundary path classification, and the review-diff-base
# resolution (dirty → HEAD; clean+ahead → range).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/emit-git-facts.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Hermetic gh: a stub that always fails, so the PR fact exercises its
# `|| echo "none"` fallback with zero network / auth dependence. (A real no-remote
# repo also yields "none", but the stub keeps the suite fast and deterministic in
# CI regardless of gh auth state.) git stays real — only gh is shadowed.
STUB_BIN="$TEST_TMPDIR/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_BIN/gh"
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# run_detector <dir> — run the detector with <dir> as the caller's cwd.
run_detector() { (cd "$1" && bash "$SCRIPT"); }

# fact <output> <label> — extract the value following "<label>: " on its line.
fact() {
  printf '%s\n' "$1" | grep -E "^$2: " | head -1 | sed -E "s/^$2: //"
}

# --- Case 1: --help exits 0 with non-empty stdout ---

help_out=$(bash "$SCRIPT" --help)
assert_exit "--help exits 0" 0 "$?"
if [[ -n "$help_out" ]]; then
  pass "--help emits non-empty stdout"
else
  fail "--help emits non-empty stdout" "non-empty" "(empty)"
fi
assert_contains "--help mentions usage" "$help_out" "Usage:"

# --- Case 2: -h is an alias for --help ---

h_out=$(bash "$SCRIPT" -h)
assert_exit "-h exits 0" 0 "$?"
assert_eq "-h == --help" "$help_out" "$h_out"

# --- Case 3: all nine fact labels present (inside a repo) ---

REPO3="$TEST_TMPDIR/repo3"
make_repo "$REPO3"
out3=$(run_detector "$REPO3")
for label in \
  "Current branch" \
  "Working tree status" \
  "Recent commits" \
  "Changed files (staged+unstaged)" \
  "Open PR for branch" \
  "Security-sensitive paths touched" \
  "Layer-boundary paths touched" \
  "Diff size (lines changed, tracked)" \
  "Review diff base"; do
  assert_contains "label present: $label" "$out3" "$label: "
done

# --- Case 4: detector always exits 0 (never crashes a consuming !-block) ---

run_detector "$REPO3" >/dev/null 2>&1
assert_exit "exits 0 inside a repo" 0 "$?"

# --- Case 5: fresh repo — branch fact matches, diff size 0, classifications none ---

(cd "$REPO3" && git checkout -q -b feat/sample)
out5=$(run_detector "$REPO3")
assert_eq "branch fact matches actual branch" "feat/sample" "$(fact "$out5" "Current branch")"
assert_eq "diff size 0 on clean tree" "0" "$(fact "$out5" "Diff size \(lines changed, tracked\)")"
assert_eq "no security paths on clean tree" "none" "$(fact "$out5" "Security-sensitive paths touched")"
assert_eq "no layer paths on clean tree" "none" "$(fact "$out5" "Layer-boundary paths touched")"

# --- Case 6: non-repo — graceful degradation, exit 0 ---

NONREPO="$TEST_TMPDIR/not-a-repo"
mkdir -p "$NONREPO"
out6=$(run_detector "$NONREPO")
run_detector "$NONREPO" >/dev/null 2>&1
assert_exit "exits 0 outside a repo" 0 "$?"
assert_eq "branch → unknown outside repo" "unknown" "$(fact "$out6" "Current branch")"
assert_eq "commits → no commits outside repo" "no commits" "$(fact "$out6" "Recent commits")"
assert_eq "changed → none outside repo" "none" "$(fact "$out6" "Changed files \(staged\+unstaged\)")"
assert_eq "diff size → 0 outside repo" "0" "$(fact "$out6" "Diff size \(lines changed, tracked\)")"
assert_eq "working-tree status → empty outside repo (not 'clean')" "" "$(fact "$out6" "Working tree status")"
assert_eq "review diff base → HEAD outside repo (graceful, no remote)" "HEAD" "$(fact "$out6" "Review diff base")"
# Empty status line must still terminate (no gluing onto the next label).
assert_contains "non-repo keeps Recent-commits label on its own line" "$out6" $'\nRecent commits: '

# --- Case 7: cwd-invariance — output identical from repo root and a subdir ---

REPO7="$TEST_TMPDIR/repo7"
make_repo "$REPO7"
mkdir -p "$REPO7/nested/deep"
printf 'x\n' >"$REPO7/tracked.txt"
(cd "$REPO7" && git add tracked.txt)
out_root=$(run_detector "$REPO7")
out_sub=$(run_detector "$REPO7/nested/deep")
assert_eq "cwd-invariant: root output == subdir output" "$out_root" "$out_sub"

# --- Case 8: gh-unavailable — PR fact falls back AND later facts survive ---
# The global gh stub already exits 1; assert the PR fact degrades to "none" and
# that the diff-size fact emitted AFTER it is still present (proves no `set -e`
# abort dropped subsequent facts).

out8=$(run_detector "$REPO7")
assert_eq "PR fact → none when gh fails" "none" "$(fact "$out8" "Open PR for branch")"
diff_after_pr=$(fact "$out8" "Diff size \(lines changed, tracked\)")
if [[ "$diff_after_pr" =~ ^[0-9]+$ ]]; then
  pass "fact after the failing gh call still emitted (no set -e abort)"
else
  fail "fact after the failing gh call still emitted (no set -e abort)" "<integer>" "$diff_after_pr"
fi

# --- Case 9: security-sensitive path classification fires ---

REPO9="$TEST_TMPDIR/repo9"
make_repo "$REPO9"
mkdir -p "$REPO9/apps/identity-server"
printf '// auth\n' >"$REPO9/apps/identity-server/AuthService.cs"
(cd "$REPO9" && git add apps/identity-server/AuthService.cs)
out9=$(run_detector "$REPO9")
assert_contains "security path classified" \
  "$(fact "$out9" "Security-sensitive paths touched")" "apps/identity-server/AuthService.cs"

# --- Case 10: layer-boundary path classification fires ---

REPO10="$TEST_TMPDIR/repo10"
make_repo "$REPO10"
mkdir -p "$REPO10/libs/Platform.Core"
printf '<Project/>\n' >"$REPO10/libs/Platform.Core/Platform.Core.csproj"
(cd "$REPO10" && git add libs/Platform.Core/Platform.Core.csproj)
out10=$(run_detector "$REPO10")
assert_contains "layer path classified (.csproj)" \
  "$(fact "$out10" "Layer-boundary paths touched")" "libs/Platform.Core/Platform.Core.csproj"

# --- Case 11: a Domain/ segment also classifies as layer-boundary ---

REPO11="$TEST_TMPDIR/repo11"
make_repo "$REPO11"
mkdir -p "$REPO11/src/Modules/Template/Domain"
printf '// item\n' >"$REPO11/src/Modules/Template/Domain/Item.cs"
(cd "$REPO11" && git add src/Modules/Template/Domain/Item.cs)
out11=$(run_detector "$REPO11")
assert_contains "layer path classified (Domain/)" \
  "$(fact "$out11" "Layer-boundary paths touched")" "src/Modules/Template/Domain/Item.cs"

# --- Case 12: a plain doc change classifies as neither security nor layer ---

REPO12="$TEST_TMPDIR/repo12"
make_repo "$REPO12"
printf '# notes\n' >"$REPO12/NOTES.md"
(cd "$REPO12" && git add NOTES.md)
out12=$(run_detector "$REPO12")
assert_eq "plain doc → no security match" "none" "$(fact "$out12" "Security-sensitive paths touched")"
assert_eq "plain doc → no layer match" "none" "$(fact "$out12" "Layer-boundary paths touched")"
assert_contains "plain doc appears in changed files" \
  "$(fact "$out12" "Changed files \(staged\+unstaged\)")" "NOTES.md"

# --- Case 13: output is LF-clean (cross-platform byte-identity guard) ---

raw_bytes=$(run_detector "$REPO7" | wc -c | tr -d ' ')
stripped_bytes=$(run_detector "$REPO7" | tr -d '\r' | wc -c | tr -d ' ')
assert_eq "output is LF-clean (no CR bytes)" "$raw_bytes" "$stripped_bytes"

# --- Case 14: untracked-only, not ahead → review base HEAD ---
# No tracked uncommitted changes + no remote to be ahead of → HEAD via the
# fallthrough. The untracked file still shows in the porcelain "Working tree
# status" fact (which the clean-tree short-circuit consults separately), but it
# does NOT drive review-base resolution — review base keys on `git diff HEAD`.

REPO14="$TEST_TMPDIR/repo14"
make_repo "$REPO14"
printf 'scratch\n' >"$REPO14/untracked.txt"
out14=$(run_detector "$REPO14")
assert_eq "untracked-only, not ahead → review base HEAD" "HEAD" "$(fact "$out14" "Review diff base")"
assert_contains "untracked file shows in working-tree status (?? marker)" \
  "$(fact "$out14" "Working tree status")" "untracked.txt"

# --- Case 15: unstaged tracked change classifies (git diff HEAD covers unstaged) ---
# Cases 9–11 stage via `git add`; this modifies a committed tracked file WITHOUT
# staging to prove the security/layer globs (and changed-files fact) cover the
# unstaged code path, not just staged.

REPO15="$TEST_TMPDIR/repo15"
make_repo "$REPO15"
mkdir -p "$REPO15/apps/identity-server"
printf '// v1\n' >"$REPO15/apps/identity-server/AuthService.cs"
(cd "$REPO15" && git add apps/identity-server/AuthService.cs && git commit -q -m "add auth")
printf '// v2 modified\n' >>"$REPO15/apps/identity-server/AuthService.cs" # unstaged edit
out15=$(run_detector "$REPO15")
assert_contains "unstaged security file classified (git diff HEAD covers unstaged)" \
  "$(fact "$out15" "Security-sensitive paths touched")" "apps/identity-server/AuthService.cs"

# --- Case 16: clean tree ahead of remote default → range review base ---
# Committed-clean branch with the remote default behind it: `git diff HEAD` is
# empty, so review surfaces must diff the origin/<default>...HEAD range instead
# (the open-PR / committed-branch case Codex flagged). Uses a local bare remote;
# symbolic-ref forces `main` regardless of init.defaultBranch (portable per
# docs/ecosystems/bash-gotchas-reference.md "git init -b may detach HEAD").

REPO16="$TEST_TMPDIR/repo16"
mkdir -p "$REPO16"
git -C "$REPO16" init -q
git -C "$REPO16" symbolic-ref HEAD refs/heads/main
git -C "$REPO16" config user.email t@example.local
git -C "$REPO16" config user.name testuser
git -C "$REPO16" commit --allow-empty -q -m init
REMOTE16="$TEST_TMPDIR/remote16.git"
git init -q --bare "$REMOTE16"
git -C "$REPO16" remote add origin "$REMOTE16"
git -C "$REPO16" push -q origin main
git -C "$REPO16" remote set-head origin main
git -C "$REPO16" commit --allow-empty -q -m "ahead of base"
out16=$(run_detector "$REPO16")
assert_eq "clean branch ahead of base → range review base" \
  "origin/main...HEAD" "$(fact "$out16" "Review diff base")"

# --- Case 17: committed-ahead branch — untracked vs tracked-dirty precedence ---
# Regression for the untracked-scratch-on-committed-branch bug: an incidental
# untracked file must NOT force HEAD (git diff HEAD is empty on a committed-clean
# tree → leaves would see nothing); the committed range is the review target.
# A TRACKED uncommitted change, by contrast, IS in-progress work → HEAD wins.

REPO17="$TEST_TMPDIR/repo17"
mkdir -p "$REPO17"
git -C "$REPO17" init -q
git -C "$REPO17" symbolic-ref HEAD refs/heads/main
git -C "$REPO17" config user.email t@example.local
git -C "$REPO17" config user.name testuser
printf 'base\n' >"$REPO17/tracked.txt"
git -C "$REPO17" add tracked.txt
git -C "$REPO17" commit -q -m init
REMOTE17="$TEST_TMPDIR/remote17.git"
git init -q --bare "$REMOTE17"
git -C "$REPO17" remote add origin "$REMOTE17"
git -C "$REPO17" push -q origin main
git -C "$REPO17" remote set-head origin main
printf 'committed change\n' >>"$REPO17/tracked.txt"
git -C "$REPO17" commit -aq -m "ahead of base"
printf 'scratch\n' >"$REPO17/scratch.txt" # incidental untracked file
out17=$(run_detector "$REPO17")
assert_eq "committed-ahead + untracked scratch → range (untracked must not force HEAD)" \
  "origin/main...HEAD" "$(fact "$out17" "Review diff base")"
printf 'wip\n' >>"$REPO17/tracked.txt" # now a TRACKED uncommitted change
out17b=$(run_detector "$REPO17")
assert_eq "committed-ahead + tracked uncommitted change → HEAD (in-progress wins)" \
  "HEAD" "$(fact "$out17b" "Review diff base")"

[[ $FAILED -eq 0 ]] || exit 1
