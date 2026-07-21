#!/usr/bin/env bash
# Deterministic evidence backup: snapshot the local evidence surfaces (the
# repo's .artifacts/ append-only store and the OTel session store) into a
# timestamped folder under a configurable backup root, then prune to the last N
# snapshots. Zero agent tokens by design -- a plain OS-scheduler entrypoint (to
# be wired to the Windows scheduler later; this is the script only).
#
# Config:
#   DRAIN_BACKUP_ROOT    backup destination root (REQUIRED; no machine-literal
#                        default — unset fails closed)
#   DRAIN_OTEL_STORE     OTel session store to snapshot (resolved by
#                        drain_otel_store: env -> binding run_link_prefix)
#   DRAIN_BACKUP_RETAIN  snapshots to keep (default 14)
#
# Usage: backup-evidence.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=drain-common.sh
source "$SCRIPT_DIR/drain-common.sh"

backup_root="${DRAIN_BACKUP_ROOT:-}"
[[ -n "$backup_root" ]] || {
  echo "backup-evidence.sh: set DRAIN_BACKUP_ROOT to the backup destination root (no machine-literal default)" >&2
  exit 2
}
store="$(drain_otel_store)"
retain="${DRAIN_BACKUP_RETAIN:-14}"
[[ "$retain" =~ ^[0-9]+$ ]] || {
  echo "backup-evidence.sh: DRAIN_BACKUP_RETAIN must be a non-negative integer" >&2
  exit 2
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${backup_root}/${stamp}"
mkdir -p "$dest"

copied=0
if [[ -d "$DRAIN_ARTIFACT_DIR" ]]; then
  cp -r "$DRAIN_ARTIFACT_DIR" "${dest}/artifacts"
  copied=1
fi
if [[ -d "$store" ]]; then
  cp -r "$store" "${dest}/otel-store"
  copied=1
fi
if [[ "$copied" -eq 0 ]]; then
  echo "backup-evidence.sh: neither ${DRAIN_ARTIFACT_DIR} nor ${store} exists; empty snapshot ${dest}" >&2
fi

# Prune: keep the newest N timestamped snapshots (names sort chronologically).
mapfile -t snaps < <(for d in "${backup_root}"/2*/; do [[ -d "$d" ]] && basename "$d"; done | sort)
count="${#snaps[@]}"
if [[ "$count" -gt "$retain" ]]; then
  remove=$((count - retain))
  for ((k = 0; k < remove; k++)); do
    rm -rf "${backup_root:?}/${snaps[k]}"
    echo "backup-evidence.sh: pruned old snapshot ${snaps[k]}"
  done
fi

echo "backup-evidence.sh: snapshot ${dest} (retaining last ${retain})"
