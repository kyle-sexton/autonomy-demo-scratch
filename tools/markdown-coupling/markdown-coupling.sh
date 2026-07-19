#!/usr/bin/env bash
# Unified markdown-coupling CLI dispatcher.
#
# Usage:
#   bash tools/markdown-coupling/markdown-coupling.sh <subcommand> [args...]
#
# Subcommands delegate to existing entry scripts with a shared --root flag.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # reserved for subcommand delegation
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"

usage() {
  cat <<'EOF'
Usage: markdown-coupling.sh <subcommand> [args...]

Subcommands:
  check-cites          Heading-cite resolver (reference-integrity gate)
  corpus-diff          Branch delta ∩ durable corpus paths (quality-gate scope)
  measure              Coupling measurement orchestrator

Common flags (forwarded where supported):
  --root <dir>         Repo root (default: git toplevel)
  --help               Subcommand help

Examples:
  bash tools/markdown-coupling/markdown-coupling.sh measure --dry-run
  bash tools/markdown-coupling/markdown-coupling.sh check-cites --help
EOF
}

subcommand="${1:-}"
case "$subcommand" in
  --help | -h | '')
    usage
    exit 0
    ;;
  check-cites)
    shift
    exec bash "$SCRIPT_DIR/check-heading-cites.sh" "$@"
    ;;
  corpus-diff)
    shift
    exec bash "$SCRIPT_DIR/corpus-diff.sh" "$@"
    ;;
  measure)
    shift
    exec bash "$SCRIPT_DIR/measure.sh" "$@"
    ;;
  *)
    echo "ERROR: unknown subcommand: $subcommand" >&2
    usage >&2
    exit 2
    ;;
esac
