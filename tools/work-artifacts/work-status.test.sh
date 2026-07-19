#!/usr/bin/env bash
# Regression tests for tools/work-artifacts/work-status.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/work-status.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# write_readme <repo> <slug> <status> <updated> [priority] [issue] [pr]
write_readme() {
  local repo="$1" slug="$2" status="$3" updated="$4" priority="${5:-}" issue="${6:-}" pr="${7:-}"
  local dir="$repo/.work/$slug"
  local slug_title="" _word
  for _word in ${slug//-/ }; do
    slug_title+="${_word^} "
  done
  slug_title="${slug_title% }"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'status: %s\n' "$status"
    printf 'created: %s\n' "$updated"
    printf 'updated: %s\n' "$updated"
    [[ -n "$priority" ]] && printf 'priority: %s\n' "$priority"
    [[ -n "$issue" ]] && printf 'issue: %s\n' "$issue"
    [[ -n "$pr" ]] && printf 'pr: %s\n' "$pr"
    printf -- '---\n\n# %s\n' "$slug_title"
  } >"$dir/README.md"
}

# write_plan <repo> <slug>  (PLAN body on stdin)
write_plan() {
  local dir="$1/.work/$2"
  mkdir -p "$dir"
  cat >"$dir/PLAN.md"
}

# --- Case 1: --help exits 0 with non-empty stdout ---

help_out="$(bash "$SCRIPT" --help)"
assert_exit "--help exit 0" 0 "$?"
assert_contains "--help prints usage" "$help_out" "work-status.sh"

# --- Index ---

REPO="$TEST_TMPDIR/repo"
make_repo "$REPO"
write_readme "$REPO" "alpha" "in-progress" "2026-06-01" "p1" "1234" ""
write_readme "$REPO" "bravo" "done" "2026-06-02" "" "" "55"

idx="$(cd "$REPO" && bash "$SCRIPT")"
assert_exit "index exit 0" 0 "$?"
assert_contains "index lists alpha" "$idx" "alpha"
assert_contains "index lists bravo" "$idx" "bravo"
assert_contains "index shows priority" "$idx" "p1"
assert_contains "index shows issue tracker" "$idx" "issue:#1234"
assert_contains "index shows pr tracker" "$idx" "pr:#55"
assert_contains "index header present" "$idx" "slug"

# sort: bravo (2026-06-02) must appear before alpha (2026-06-01)
bravo_line="$(printf '%s\n' "$idx" | grep -n '^bravo' | cut -d: -f1)"
alpha_line="$(printf '%s\n' "$idx" | grep -n '^alpha' | cut -d: -f1)"
if [[ -n "$bravo_line" && -n "$alpha_line" && "$bravo_line" -lt "$alpha_line" ]]; then
  pass "index sorted updated desc (bravo before alpha)"
else
  fail "index sorted updated desc" "bravo<alpha" "bravo=$bravo_line alpha=$alpha_line"
fi

# --- Index: empty repo ---

EMPTY="$TEST_TMPDIR/empty"
make_repo "$EMPTY"
empty_out="$(cd "$EMPTY" && bash "$SCRIPT")"
assert_exit "empty index exit 0" 0 "$?"
assert_contains "empty index message" "$empty_out" "no .work/ slices"

# --- Phases: mixed DONE+DOING+TODO → in-progress ---

write_readme "$REPO" "mixed" "in-progress" "2026-06-02"
write_plan "$REPO" "mixed" <<'EOF'
## Brief
scope.

## Plan

### Phase 1: setup [DONE]
- [x] **Sanity Check:** built.

### Phase 2: core [DOING]
- [ ] **Sanity Check:** wip.

### Phase 3: polish [TODO]
- [ ] **Sanity Check:** todo.
EOF
ph_mixed="$(cd "$REPO" && bash "$SCRIPT" --phases mixed)"
assert_exit "--phases exit 0" 0 "$?"
assert_contains "phases echoes Phase 1 line" "$ph_mixed" "Phase 1: setup [DONE]"
assert_contains "mixed rollup in-progress" "$ph_mixed" "computed rollup: in-progress"

# --- Phases: all DONE → done ---

write_readme "$REPO" "finished" "done" "2026-06-02"
write_plan "$REPO" "finished" <<'EOF'
## Plan

### Phase 1: a [DONE]
- [x] x

### Phase 2: b [DONE]
- [x] y
EOF
ph_done="$(cd "$REPO" && bash "$SCRIPT" --phases finished)"
assert_contains "all-done rollup done" "$ph_done" "computed rollup: done"

# --- Phases: any BLOCKED → blocked ---

write_readme "$REPO" "stuck" "blocked" "2026-06-02"
write_plan "$REPO" "stuck" <<'EOF'
## Plan

### Phase 1: a [DONE]
- [x] x

### Phase 2: b [BLOCKED]
- [ ] y
EOF
ph_blocked="$(cd "$REPO" && bash "$SCRIPT" --phases stuck)"
assert_contains "blocked rollup blocked" "$ph_blocked" "computed rollup: blocked"

# --- Phases: README/rollup mismatch → advisory NOTE ---

write_readme "$REPO" "mismatch" "done" "2026-06-02"
write_plan "$REPO" "mismatch" <<'EOF'
## Plan

### Phase 1: a [DOING]
- [ ] x
EOF
ph_mm="$(cd "$REPO" && bash "$SCRIPT" --phases mismatch)"
assert_contains "mismatch advisory NOTE" "$ph_mm" "NOTE: README status"

# --- Phases: abandoned README status is a legit override, no NOTE ---

write_readme "$REPO" "dropped" "abandoned" "2026-06-02"
write_plan "$REPO" "dropped" <<'EOF'
## Plan

### Phase 1: a [DOING]
- [ ] x
EOF
ph_drop="$(cd "$REPO" && bash "$SCRIPT" --phases dropped)"
assert_not_contains "abandoned override = no NOTE" "$ph_drop" "NOTE: README status"

# --- Phases: XS slice (no PLAN) → README authoritative ---

write_readme "$REPO" "tiny" "done" "2026-06-02"
ph_xs="$(cd "$REPO" && bash "$SCRIPT" --phases tiny)"
assert_contains "XS slice message" "$ph_xs" "no PLAN.md"

# --- Index: nested EPIC sub-slice slug rendered with path ---

write_readme "$REPO" "epic/sub-a" "in-progress" "2026-06-03"
idx_nested="$(cd "$REPO" && bash "$SCRIPT")"
assert_contains "index lists nested sub-slice slug" "$idx_nested" "epic/sub-a"

# --- Index: frontmatter-less README → ?/0000-00-00 fallback, sorts last ---

mkdir -p "$REPO/.work/nofm"
printf '# Nofm\n\nNo frontmatter — manifest stub not yet filled.\n' >"$REPO/.work/nofm/README.md"
idx_nofm="$(cd "$REPO" && bash "$SCRIPT")"
assert_contains "index lists frontmatter-less slug" "$idx_nofm" "nofm"
nofm_last="$(printf '%s\n' "$idx_nofm" | grep -v '^$' | tail -1)"
assert_contains "frontmatter-less sorts last (0000-00-00 updated)" "$nofm_last" "nofm"
assert_contains "frontmatter-less status fallback ?" "$nofm_last" "?"

# --- Usage errors ---

(cd "$REPO" && bash "$SCRIPT" --phases >/dev/null 2>&1)
assert_exit "--phases without slug → exit 2" 2 "$?"

(cd "$REPO" && bash "$SCRIPT" --bogus >/dev/null 2>&1)
assert_exit "unknown arg → exit 2" 2 "$?"

[[ $FAILED -eq 0 ]] || exit 1
