#!/usr/bin/env bash
# Optional host Grok smoke — install, auth, headless reply (no Docker). Writes verify artifact.
#
# Usage: bash tools/grok-build/record-host-smoke.sh <verify-dir>
#   Or set GROK_HOST_SMOKE_VERIFY_DIR when the slice verify path is known at runtime.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_DIR="${1:-${GROK_HOST_SMOKE_VERIFY_DIR:-}}"
if [[ -z "$VERIFY_DIR" ]]; then
  echo "record-host-smoke.sh: pass verify output directory (or set GROK_HOST_SMOKE_VERIFY_DIR)" >&2
  exit 2
fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${VERIFY_DIR}/${STAMP}-grok-host-smoke.md"

mkdir -p "$VERIFY_DIR"

GROK_BIN="${GROK_BIN:-grok}"
if ! command -v "$GROK_BIN" >/dev/null 2>&1; then
  echo "FAIL: grok not on PATH (set GROK_BIN)" >&2
  exit 1
fi

AUTH_NOTE="MISSING — run grok login"
if [[ -f "${HOME}/.grok/auth.json" ]]; then
  AUTH_NOTE="present (~/.grok/auth.json)"
elif [[ -n "${USERPROFILE:-}" && -f "${USERPROFILE}/.grok/auth.json" ]]; then
  AUTH_NOTE="present (${USERPROFILE}/.grok/auth.json)"
fi

{
  echo "# Grok host smoke — ${STAMP}"
  echo ""
  echo "## Environment"
  echo "- grok: \`$("$GROK_BIN" --no-auto-update --version 2>&1 | head -1)\`"
  echo "- cwd: \`$ROOT\`"
  echo "- auth: ${AUTH_NOTE}"
  echo ""
  echo "## inspect (repo root)"
  echo '```text'
  (cd "$ROOT" && "$GROK_BIN" --no-auto-update inspect 2>&1 | head -45) || true
  echo '```'
  echo ""
  echo "## headless smoke"
  echo ""
  echo "> Transient \`Auth(AuthorizationRequired)\` stderr before success is normal on cold start. Re-run \`grok login\` if exit non-zero persists."
  echo ""
  echo '```text'
  if timeout 300 "$GROK_BIN" --no-auto-update -p "Reply with exactly: ok" \
    --output-format plain --always-approve 2>&1; then
    echo "exit: 0"
  else
    echo "exit: $?"
  fi
  echo '```'
} >"$OUT"

echo "Wrote $OUT"
