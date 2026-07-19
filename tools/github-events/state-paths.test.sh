#!/usr/bin/env bash
# Regression tests for tools/github-events/state-paths.sh.
#
# Source the lib (pure, include-guarded) and drive ghe::resolve_state_paths with
# env overrides. Focus: the empty-slug guard + slug sanitization.
#
# Run: bash tools/github-events/state-paths.test.sh
# Or:  bash tools/run-shell-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/state-paths.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# shellcheck source=./state-paths.sh
source "$LIB"

# All cases pin STATE_DIR so assertions don't depend on the host's LOCALAPPDATA.
export GITHUB_EVENTS_STATE_DIR="$TEST_TMPDIR/state"

# --- Case: normal override slug passes through unchanged -----------------------
GITHUB_EVENTS_REPO_SLUG="my-repo" ghe::resolve_state_paths
assert_eq "normal override slug" "my-repo" "$GHE_REPO_SLUG"
assert_eq "normal override port file" "$TEST_TMPDIR/state/broker-my-repo.ports.json" "$GHE_PORT_FILE"

# --- Case: unsafe characters in override are sanitized to hyphens --------------
GITHUB_EVENTS_REPO_SLUG="a/b c.d" ghe::resolve_state_paths
assert_eq "unsafe chars sanitized" "a-b-c-d" "$GHE_REPO_SLUG"

# --- Case: all-separator override collapses to empty -> sentinel -----------
# "---" sanitizes to "" (leading/trailing hyphen strip). Without the guard the
# port file would be "broker-.ports.json", shared across every empty-slug context.
GITHUB_EVENTS_REPO_SLUG="---" ghe::resolve_state_paths
assert_eq "all-separator slug -> sentinel" "unknown-repo" "$GHE_REPO_SLUG"
assert_eq "sentinel port file (no broker-. collapse)" \
  "$TEST_TMPDIR/state/broker-unknown-repo.ports.json" "$GHE_PORT_FILE"

# --- Case: watcher pid/lock are slugged (per-repo, not machine-global) ---------
# Latent multi-repo collision fix: a non-slugged watcher.pid would collide across
# repos sharing one machine. Override slug -> watcher-<slug>.pid/.ready/.lock.
GITHUB_EVENTS_REPO_SLUG="my-repo" ghe::resolve_state_paths
assert_eq "slugged watcher pid" "$TEST_TMPDIR/state/watcher-my-repo.pid" "$GHE_PID_FILE"
assert_eq "slugged ready sentinel" "$TEST_TMPDIR/state/watcher-my-repo.pid.ready" "$GHE_READY_FILE"
assert_eq "slugged lock dir" "$TEST_TMPDIR/state/watcher-my-repo.pid.lock" "$GHE_LOCK_DIR"

# --- Case: parse_remote_url (pure) — every common origin form -> owner/repo ----
# Shared vectors with env.test.ts + slug-parity.test.sh. Byte-identical output is
# the cross-language contract: a divergence here silently kills channel mode.
assert_eq "ssh scp form" "melodic-software/medley" "$(ghe::parse_remote_url 'git@github.com:melodic-software/medley.git')"
assert_eq "https with .git" "melodic-software/medley" "$(ghe::parse_remote_url 'https://github.com/melodic-software/medley.git')"
assert_eq "https no .git" "melodic-software/medley" "$(ghe::parse_remote_url 'https://github.com/melodic-software/medley')"
assert_eq "ssh:// scheme" "melodic-software/medley" "$(ghe::parse_remote_url 'ssh://git@github.com/melodic-software/medley.git')"
assert_eq "trailing slash" "melodic-software/medley" "$(ghe::parse_remote_url 'https://github.com/melodic-software/medley/')"
assert_eq "case preserved" "Melodic-Software/Medley" "$(ghe::parse_remote_url 'git@github.com:Melodic-Software/Medley.git')"
assert_eq "empty -> empty" "" "$(ghe::parse_remote_url '')"

# --- Case: repo identity + slug from GITHUB_EVENTS_REPO (no git call) ----------
assert_eq "identity from env" "melodic-software/medley" "$(GITHUB_EVENTS_REPO='melodic-software/medley' ghe::repo_identity)"
assert_eq "slug from env identity" "melodic-software-medley" "$(GITHUB_EVENTS_REPO='melodic-software/medley' ghe::repo_slug)"
assert_eq "slug preserves case" "Melodic-Software-Medley" "$(GITHUB_EVENTS_REPO='Melodic-Software/Medley' ghe::repo_slug)"

# --- Case: GITHUB_EVENTS_REPO drives port + watcher paths end-to-end -----------
GITHUB_EVENTS_REPO="melodic-software/medley" ghe::resolve_state_paths
assert_eq "identity exported" "melodic-software/medley" "$GHE_REPO_IDENTITY"
assert_eq "slug from identity" "melodic-software-medley" "$GHE_REPO_SLUG"
assert_eq "port file from identity" \
  "$TEST_TMPDIR/state/broker-melodic-software-medley.ports.json" "$GHE_PORT_FILE"
assert_eq "watcher pid from identity" \
  "$TEST_TMPDIR/state/watcher-melodic-software-medley.pid" "$GHE_PID_FILE"

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
