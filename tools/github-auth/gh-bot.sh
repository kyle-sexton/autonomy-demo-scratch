#!/usr/bin/env bash
# JIT GitHub App token wrapper — generates melodic-ai[bot] installation token
# on demand, delegates to gh CLI. Falls back to personal gh auth on failure.
#
# Usage: bash tools/github-auth/gh-bot.sh <gh-args...>
# Example: bash tools/github-auth/gh-bot.sh pr create --title "feat: ..." --body "..."
#
# Token is generated just-in-time via generate-token.sh (cached ~55min).
# Personal gh auth identity remains default for direct gh calls.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
Usage: gh-bot.sh [OPTIONS] <gh-args...>

JIT wrapper that runs gh CLI as melodic-ai[bot].

Options:
  --check    Test if bot identity is available (exit 0 = yes, 1 = no)
  --help     Show this help message

Examples:
  gh-bot.sh pr create --title "feat: ..." --body "..."
  gh-bot.sh issue create --title "Bug: ..." --body "..."
  gh-bot.sh api repos/melodic-software/medley/issues --method POST -f title="..."
  gh-bot.sh --check

Environment:
  Requires MELODIC_APP_ID, MELODIC_INSTALLATION_ID, and
  MELODIC_PRIVATE_KEY_PATH (or MELODIC_PRIVATE_KEY_BASE64).
  When prerequisites missing, falls back to personal gh auth.
EOF
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  --check)
    if token=$("$SCRIPT_DIR/generate-token.sh" --quiet 2>/dev/null) && [[ -n "$token" ]]; then
      echo "Bot identity available (melodic-ai[bot])"
      exit 0
    else
      echo "Bot identity unavailable — would fall back to personal gh auth" >&2
      exit 1
    fi
    ;;
esac

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

# Save stdin to fd 3 — generate-token.sh reads /dev/null but the subshell
# would otherwise inherit (and consume) caller's stdin, breaking gh commands
# that read from stdin (e.g. --body @-, --body-file -).
exec 3<&0

token=$("$SCRIPT_DIR/generate-token.sh" --quiet 2>/dev/null </dev/null) || true

# Restore stdin from fd 3 before exec-ing gh
exec 0<&3 3<&-

if [[ -n "$token" ]]; then
  GH_TOKEN="$token" exec gh "$@"
else
  echo "Warning: Bot token generation failed, using personal identity" >&2
  exec gh "$@"
fi
