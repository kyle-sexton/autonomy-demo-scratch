#!/usr/bin/env bash
# Sync Codex model catalog from committed registry into gitignored cache.
#
# Usage:
#   tools/model-routing/sync-codex-catalog.sh [OPTIONS]
#
# Options:
#   -h, --help        Print usage
#   --force           Always rebuild
#   --check-drift     Compare fresh build to cache; exit 1 on drift
#   --dry-run         Print summary to stdout; do not write cache

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sync-vendor-catalog.sh
source "$SCRIPT_DIR/lib/sync-vendor-catalog.sh"

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

FORCE=false
CHECK_DRIFT=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    --force) FORCE=true ;;
    --check-drift)
      CHECK_DRIFT=true
      FORCE=true
      ;;
    --dry-run)
      DRY_RUN=true
      FORCE=true
      ;;
    *)
      echo "sync-codex-catalog: unknown argument: $arg" >&2
      exit 3
      ;;
  esac
done

sync_vendor_catalog "codex" "$FORCE" "$CHECK_DRIFT" "$DRY_RUN"
