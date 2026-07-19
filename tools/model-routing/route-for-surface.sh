#!/usr/bin/env bash
# Pit-of-success facade: sync catalog, ensure routing.json, apply to surface.
#
# Usage:
#   tools/model-routing/route-for-surface.sh --slice <path> --surface <id> --phase <N> [OPTIONS]
#
# Options:
#   -h, --help     Print usage
#   --refresh      Regenerate routing.json from PLAN heuristic
#   --dry-run      Pass through to apply-routing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/role-map.sh
source "$SCRIPT_DIR/lib/role-map.sh"
# shellcheck source=lib/generate-routing-from-plan.sh
source "$SCRIPT_DIR/lib/generate-routing-from-plan.sh"

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SLICE=""
PHASE=""
SURFACE=""
REFRESH=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --slice)
      SLICE="$2"
      shift 2
      ;;
    --phase)
      PHASE="$2"
      shift 2
      ;;
    --surface)
      SURFACE="$2"
      shift 2
      ;;
    --refresh)
      REFRESH=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "route-for-surface: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$SLICE" || -z "$PHASE" || -z "$SURFACE" ]]; then
  echo "route-for-surface: --slice, --phase, and --surface are required" >&2
  usage >&2
  exit 3
fi

REPO_ROOT="$(model_routing_repo_root)"
SLICE_DIR="$REPO_ROOT/$SLICE"
MANIFEST="$SLICE_DIR/routing.json"
NOW="$(model_routing_iso_now)"

SYNC_ARGS=()
if [[ "$DRY_RUN" == true ]]; then
  SYNC_ARGS+=(--dry-run)
else
  SYNC_ARGS+=(--force)
fi

SYNC_SCRIPT="$(surface_sync_script "$SURFACE")"
if [[ -n "$SYNC_SCRIPT" && -f "$SCRIPT_DIR/$SYNC_SCRIPT" ]]; then
  bash "$SCRIPT_DIR/$SYNC_SCRIPT" "${SYNC_ARGS[@]}" || {
    echo "route-for-surface: catalog sync failed; try --fallback-tier via apply-routing after fixing network" >&2
    exit 2
  }
elif [[ "$DRY_RUN" != true ]]; then
  echo "route-for-surface: catalog sync not implemented for surface $SURFACE" >&2
  exit 2
fi

if [[ ! -f "$MANIFEST" || "$REFRESH" == true ]]; then
  echo "route-for-surface: generating routing.json from PLAN (refine via docs/model-routing/router-pass.md)" >&2
  generate_routing_from_plan "$SLICE_DIR" "$NOW" "$SURFACE" || exit 2
fi

APPLY_ARGS=(--slice "$SLICE" --phase "$PHASE" --surface "$SURFACE")
if [[ "$DRY_RUN" == true ]]; then
  APPLY_ARGS+=(--dry-run --emit-json)
fi

bash "$SCRIPT_DIR/apply-routing.sh" "${APPLY_ARGS[@]}" || exit $?

if [[ "$SURFACE" == agent-loop-cursor* || "$SURFACE" == agent-loop-codex* ]]; then
  cat >&2 <<EOF

Next: start agent-loop from repo root, e.g.:
  cd tools/agent-loop && npm run build && node build/run-loop.js \\
    --workspace-path $SLICE \\
    --prompt-path <your-prompt.prompt.md>

Prerequisites: spend-safety attestation per tools/agent-loop/README.md "Spend safety"
EOF
fi

exit 0
