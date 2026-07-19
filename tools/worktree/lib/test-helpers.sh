# shellcheck shell=bash
# Shared helpers for tools/worktree lib and entry script tests.

# worktree_test_install_bootstrap_stub <repo_root> [marker_path]
worktree_test_install_bootstrap_stub() {
  local repo_root="${1:-}" marker="${2:-}"
  mkdir -p "$repo_root/tools"
  if [[ -n "$marker" ]]; then
    cat >"$repo_root/tools/bootstrap.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$marker"
exit 0
EOF
  else
    cat >"$repo_root/tools/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  fi
  chmod +x "$repo_root/tools/bootstrap.sh" 2>/dev/null || true
}

# worktree_test_make_repo <path> — minimal git repo with one commit.
worktree_test_make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init --quiet
    git config user.email "worktree-test@example.com"
    git config user.name "worktree-test"
    echo "seed" >seed.txt
    git add seed.txt
    git commit --quiet -m "seed"
  )
  printf '%s' "$repo"
}

# worktree_test_add_standard_worktree <main_repo> <name>
worktree_test_add_standard_worktree() {
  local main="$1" name="$2"
  mkdir -p "$main/.worktrees"
  git -C "$main" worktree add --quiet "$main/.worktrees/$name" -b "wt-$name" 2>/dev/null
}

# worktree_test_make_bare_hub <src_repo> <hub_dir>
# Creates hub/.bare + hub/main linked worktree. Prints hub path.
worktree_test_make_bare_hub() {
  local src="$1" hub="$2"
  mkdir -p "$hub"
  git clone --bare "$src" "$hub/.bare" >/dev/null 2>&1
  local def_branch
  def_branch=$(git -C "$hub/.bare" rev-parse --abbrev-ref HEAD | tr -d '\r')
  git -C "$hub/.bare" worktree add "$hub/main" "$def_branch" >/dev/null 2>&1
  printf '%s' "$hub"
}
