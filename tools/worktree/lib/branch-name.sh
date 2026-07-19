# shellcheck shell=bash
# Branch name derivation for worktree creation — policy in .claude/rules/worktree/branch-naming.md

# Sanitize one path segment to a git-ref-safe token.
worktree_lib_sanitize_ref_segment() {
  printf '%s' "$1" \
    | tr -c 'A-Za-z0-9._-' '-' \
    | sed -E 's/\.+/./g; s/-+/-/g; s/^[-._]+//; s/[-._]+$//; s/\.lock$//'
}

# Derive Conventional-Commits-conforming branch from worktree NAME (slash-delimited type only).
worktree_lib_derive_branch_name() {
  local name="$1" safe_name="$2" type rest canonical desc

  if [[ "$name" != */* ]]; then
    printf 'chore/%s\n' "$(worktree_lib_sanitize_ref_segment "$safe_name")"
    return 0
  fi

  type="${name%%/*}"
  rest="${name#*/}"
  case "${type,,}" in
    feat | feature) canonical="feat" ;;
    fix | bugfix | hotfix) canonical="fix" ;;
    refactor) canonical="refactor" ;;
    docs | documentation | doc) canonical="docs" ;;
    chore) canonical="chore" ;;
    test | tests) canonical="test" ;;
    build) canonical="build" ;;
    perf | performance) canonical="perf" ;;
    ci) canonical="ci" ;;
    style) canonical="style" ;;
    revert) canonical="revert" ;;
    claude | codex | cursor | copilot) canonical="${type,,}" ;;
    dependabot) canonical="dependabot" ;;
    *) canonical="" ;;
  esac

  desc=$(worktree_lib_sanitize_ref_segment "$rest")
  if [[ -n "$canonical" && -n "$desc" ]]; then
    printf '%s/%s\n' "$canonical" "$desc"
    return 0
  fi
  if [[ -n "$canonical" ]]; then
    printf 'worktree: name "%s" has type "%s" but no description; using chore/ fallback (pass %s/<description> to keep the type)\n' \
      "$name" "$canonical" "$canonical" >&2
  fi
  printf 'chore/%s\n' "$(worktree_lib_sanitize_ref_segment "$safe_name")"
}

# Sanitize worktree directory name from user input.
worktree_lib_sanitize_worktree_name() {
  local name="$1"
  name="${name//$'\r'/}"
  printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/^[-.]*//; s/[-.]*$//'
}
