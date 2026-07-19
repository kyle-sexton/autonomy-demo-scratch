#!/usr/bin/env bash
# Tests for tools/worktree/lib/branch-name.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)/tests/shell/lib.sh"
source "$SCRIPT_DIR/branch-name.sh"

FAILED=0
CASE_NUM=0

derive() { worktree_lib_derive_branch_name "$1" "$2"; }

assert_eq "no slash → chore/safe" "chore/test-perf" "$(derive 'test-perf' 'test-perf')"
assert_eq "feat passthrough" "feat/login-form" "$(derive 'feat/login-form' 'feat-login-form')"
assert_eq "feature alias" "feat/login-form" "$(derive 'feature/login-form' 'feature-login-form')"
assert_eq "ci passthrough" "ci/pin-bump" "$(derive 'ci/pin-bump' 'ci-pin-bump')"
assert_eq "style passthrough" "style/format-sweep" "$(derive 'style/format-sweep' 'style-format-sweep')"
assert_eq "revert passthrough" "revert/bad-merge" "$(derive 'revert/bad-merge' 'revert-bad-merge')"
assert_eq "unknown type fallback" "chore/wip-spike" "$(derive 'wip/spike' 'wip-spike')"
assert_eq "codex cloud prefix" "codex/fix-thing" "$(derive 'codex/fix-thing' 'codex-fix-thing')"
assert_eq "dash name not cloud prefix" "chore/claude-code-updates" "$(derive 'claude-code-updates' 'claude-code-updates')"
assert_eq "dependabot nested slash" "dependabot/nuget-Foo.Bar" "$(derive 'dependabot/nuget/Foo.Bar' 'dependabot-nuget-Foo.Bar')"
assert_eq "dots collapse" "feat/a.b" "$(derive 'feat/a..b' 'feat-a..b')"
assert_eq "lock suffix stripped" "feat/x" "$(derive 'feat/x.lock' 'feat-x.lock')"

assert_eq "empty-rest fallback" "chore/feat" "$(derive 'feat/' 'feat')"
assert_eq "hotfix alias" "fix/urgent" "$(derive 'hotfix/urgent' 'hotfix-urgent')"

empty_desc_stderr=$(derive 'feat/' 'feat' 2>&1 >/dev/null)
assert_contains "empty-desc warns" "$empty_desc_stderr" "no description"

unknown_type_stderr=$(derive 'wip/spike' 'wip-spike' 2>&1 >/dev/null)
assert_not_contains "unrecognized type silent" "$unknown_type_stderr" "no description"

assert_eq "sanitize safe name" "feat-login-form" "$(worktree_lib_sanitize_worktree_name 'feat/login-form')"

[[ $FAILED -eq 0 ]] || exit 1
