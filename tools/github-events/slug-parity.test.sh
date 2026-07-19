#!/usr/bin/env bash
# Cross-language slug parity harness for github-events.
#
# The bash resolver (tools/github-events/state-paths.sh) and the TypeScript
# resolver (mcp-servers/github-events/node/src/shared/env.ts) MUST produce
# BYTE-IDENTICAL repo slugs. They cannot share code (different runtimes), so this
# harness runs BOTH over the same vectors and asserts equality — the #1
# silent-failure guard: a divergent slug makes the MCP subscriber read the wrong
# broker port file and channel mode dies with no error.
#
# Skips (does not fail) when node or the built env.js is absent — the bash unit
# tests (state-paths.test.sh) and TS unit tests (env.test.ts) still run; this
# harness is the cross-check that needs both runtimes present.
#
# Run: bash tools/github-events/slug-parity.test.sh
# Or:  bash tools/run-shell-tests.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
NODE_DIR="$REPO_ROOT/mcp-servers/github-events/node"
ENV_JS="$NODE_DIR/build/shared/env.js"

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$REPO_ROOT}/tests/shell/lib.sh"

# shellcheck source=./state-paths.sh
source "$REPO_ROOT/tools/github-events/state-paths.sh"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have node || [[ ! -f "$ENV_JS" ]]; then
  skip_suite "node or built env.js absent (cd mcp-servers/github-events/node && npm run build)"
fi

# Run a named export from the built ESM env.js. Relative specifier resolves
# against cwd for `--input-type=module -e`, so we cd into the node project.
node_parse() { # $1 = url
  (cd "$NODE_DIR" && node --input-type=module -e \
    "import('./build/shared/env.js').then(m => process.stdout.write(m.parseRemoteUrl(process.argv[1])))" \
    "$1") 2>/dev/null | tr -d '\r'
}
node_slug() { # $1 = GITHUB_EVENTS_REPO value
  # env -u clears any inherited GITHUB_EVENTS_REPO_SLUG so the identity path runs.
  (cd "$NODE_DIR" && env -u GITHUB_EVENTS_REPO_SLUG GITHUB_EVENTS_REPO="$1" node --input-type=module -e \
    "import('./build/shared/env.js').then(m => process.stdout.write(m.repoSlug()))") 2>/dev/null | tr -d '\r'
}

# Smoke: distinguish "build stale / ESM cannot import" (skip) from real divergence
# (let assertions report it). An empty result on a known-good vector means node
# could not run the built module at all.
SMOKE="$(node_parse 'git@github.com:a/b.git')"
if [[ -z "$SMOKE" ]]; then
  skip_suite "node could not import built env.js (stale build? cd mcp-servers/github-events/node && npm run build)"
fi

# --- parseRemoteUrl parity (bash == node == expected) -------------------------
# Shared vectors with state-paths.test.sh + env.test.ts.
PARSE_VECTORS=(
  "git@github.com:melodic-software/medley.git|melodic-software/medley"
  "https://github.com/melodic-software/medley.git|melodic-software/medley"
  "https://github.com/melodic-software/medley|melodic-software/medley"
  "ssh://git@github.com/melodic-software/medley.git|melodic-software/medley"
  "https://github.com/melodic-software/medley/|melodic-software/medley"
  "git@github.com:Melodic-Software/Medley.git|Melodic-Software/Medley"
)
for vec in "${PARSE_VECTORS[@]}"; do
  url="${vec%%|*}"
  expected="${vec##*|}"
  bash_out="$(ghe::parse_remote_url "$url")"
  node_out="$(node_parse "$url")"
  assert_eq "parse bash==node: $url" "$bash_out" "$node_out"
  assert_eq "parse expected: $url" "$expected" "$bash_out"
done

# --- repoSlug parity from GITHUB_EVENTS_REPO identity (bash == node == expected)
SLUG_VECTORS=(
  "melodic-software/medley|melodic-software-medley"
  "Melodic-Software/Medley|Melodic-Software-Medley"
)
for vec in "${SLUG_VECTORS[@]}"; do
  repo="${vec%%|*}"
  expected="${vec##*|}"
  bash_out="$(GITHUB_EVENTS_REPO="$repo" GITHUB_EVENTS_REPO_SLUG="" ghe::repo_slug)"
  node_out="$(node_slug "$repo")"
  assert_eq "slug bash==node: $repo" "$bash_out" "$node_out"
  assert_eq "slug expected: $repo" "$expected" "$bash_out"
done

[[ $FAILED -eq 0 ]] || exit 1
printf '\nAll %d checks passed.\n' "$CASE_NUM"
