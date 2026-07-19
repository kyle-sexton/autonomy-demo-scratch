#!/usr/bin/env bash
# Apply routing.json manifest to a harness-native config.
#
# Usage:
#   tools/model-routing/apply-routing.sh --slice <path> --phase <N> --surface <id> [OPTIONS]
#
# Options:
#   -h, --help           Print usage
#   --dry-run            Print output only
#   --emit-json          Print resolved JSON to stdout
#   --fallback-tier T    Use policy tier when catalog missing (standard|elevated|frontier)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/role-map.sh
source "$SCRIPT_DIR/lib/role-map.sh"
# shellcheck source=lib/resolve-model-slug.sh
source "$SCRIPT_DIR/lib/resolve-model-slug.sh"

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SLICE=""
PHASE=""
SURFACE=""
DRY_RUN=false
EMIT_JSON=false
FALLBACK_TIER=""

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
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --emit-json)
      EMIT_JSON=true
      shift
      ;;
    --fallback-tier)
      FALLBACK_TIER="$2"
      shift 2
      ;;
    *)
      echo "apply-routing: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$SLICE" || -z "$PHASE" || -z "$SURFACE" ]]; then
  echo "apply-routing: --slice, --phase, and --surface are required" >&2
  usage >&2
  exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "apply-routing: jq required" >&2
  exit 2
fi

REPO_ROOT="$(model_routing_repo_root)"
SLICE_DIR="$REPO_ROOT/$SLICE"
MANIFEST="$SLICE_DIR/routing.json"
NOW="$(model_routing_iso_now)"

CATALOG_NAMESPACE="$(surface_catalog_namespace "$SURFACE")"
if [[ -z "$CATALOG_NAMESPACE" ]]; then
  echo "apply-routing: unknown surface: $SURFACE" >&2
  exit 3
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "apply-routing: missing $MANIFEST" >&2
  echo "Run: bash tools/model-routing/route-for-surface.sh --slice $SLICE --surface $SURFACE --phase $PHASE" >&2
  echo "Or: Read docs/model-routing/router-pass.md to author routing.json" >&2
  exit 1
fi

MODEL_ID="$(jq -r --argjson p "$PHASE" '.phases[] | select(.phase == $p) | .catalogModelId' "$MANIFEST" | head -1)"
VARIANT="$(jq -r --argjson p "$PHASE" '.phases[] | select(.phase == $p) | .variant // ""' "$MANIFEST" | head -1)"
ROLE_HINT="$(jq -r --argjson p "$PHASE" '.phases[] | select(.phase == $p) | .roleHint // ""' "$MANIFEST" | head -1)"
PHASE_NAMESPACE="$(jq -r --argjson p "$PHASE" '.phases[] | select(.phase == $p) | .catalogNamespace // ""' "$MANIFEST" | head -1)"

if [[ -n "$PHASE_NAMESPACE" && "$PHASE_NAMESPACE" != "null" ]]; then
  CATALOG_NAMESPACE="$PHASE_NAMESPACE"
fi

if [[ -z "$MODEL_ID" || "$MODEL_ID" == "null" ]]; then
  if [[ -n "$FALLBACK_TIER" ]]; then
    FALLBACK_ROLE="$(complexity_fallback_role "$FALLBACK_TIER")"
    if [[ -z "$FALLBACK_ROLE" ]]; then
      echo "apply-routing: unknown fallback tier: $FALLBACK_TIER" >&2
      exit 3
    fi
    MODEL_ID="$(role_map_lookup "$CATALOG_NAMESPACE" "$FALLBACK_ROLE" "catalogModelId")"
    VARIANT="$(role_map_lookup "$CATALOG_NAMESPACE" "$FALLBACK_ROLE" "variant")"
    ROLE_HINT="$FALLBACK_ROLE"
  else
    echo "apply-routing: no phase $PHASE in manifest" >&2
    exit 1
  fi
fi

if [[ -z "$VARIANT" || "$VARIANT" == "null" ]]; then
  VARIANT=""
fi

SLUG="$(resolve_model_slug "$CATALOG_NAMESPACE" "$MODEL_ID" "$VARIANT")" || exit 2

RESULT="$(jq -n \
  --arg slug "$SLUG" \
  --arg modelId "$MODEL_ID" \
  --arg surface "$SURFACE" \
  --arg namespace "$CATALOG_NAMESPACE" \
  --argjson phase "$PHASE" \
  --arg roleHint "$ROLE_HINT" \
  --arg fetchedAt "$NOW" \
  '{ phase: $phase, surface: $surface, catalogNamespace: $namespace, catalogModelId: $modelId, modelSlug: $slug, roleHint: $roleHint, catalogFetchedAt: $fetchedAt }')"

case "$SURFACE" in
  agent-loop-cursor | agent-loop-codex)
    RUN_LOCAL="$REPO_ROOT/tools/agent-loop/run.local.json"
    OUT="$(jq -n --arg model "$SLUG" '{ model: $model, role: "implement" }')"
    if [[ "$DRY_RUN" == true || "$EMIT_JSON" == true ]]; then
      echo "$OUT"
    else
      printf '%s\n' "$OUT" >"$RUN_LOCAL"
      echo "apply-routing: wrote $RUN_LOCAL (model=$SLUG)" >&2
    fi
    ;;
  interactive)
    echo "Session model: select $SLUG in model picker (Cmd+/)." >&2
    echo "$RESULT"
    ;;
  cc-goal)
    GOAL="$(jq -r --argjson p "$PHASE" '.phases[] | select(.phase == $p) | .goalCondition // "until PLAN sanity checks pass"' "$MANIFEST")"
    echo "/goal ORCHESTRATE: execute phase $PHASE with worker model $SLUG until $GOAL"
    echo "CC runtime pins: rate-limit-aware-workflow.md + ADR 0011 — manifest is audit; set session model per policy." >&2
    ;;
  *)
    echo "apply-routing: unsupported surface: $SURFACE" >&2
    exit 3
    ;;
esac

if [[ "$EMIT_JSON" == true ]]; then
  echo "$RESULT"
fi

exit 0
