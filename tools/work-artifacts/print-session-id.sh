#!/usr/bin/env bash
# Print the current Claude Code session ID ($CLAUDE_CODE_SESSION_ID), or the
# literal "unknown" when unset. Exists so skill `!`-precompute blocks can
# resolve the session ID without inline ${...} expansion — CC's skill
# dynamic-context guard rejects commands containing shell expansion.

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
print-session-id.sh — print $CLAUDE_CODE_SESSION_ID, or "unknown" when unset

Usage:
  print-session-id.sh [--help]

Output:
  The session UUID on stdout, or the literal string "unknown".
USAGE
  exit 0
fi

printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-unknown}"
