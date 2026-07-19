#!/usr/bin/env bash
# shellcheck shell=bash
# Deterministic routing.json stub from PLAN blast radius (no LLM).

set -uo pipefail

# shellcheck source=role-map.sh
source "$(dirname "${BASH_SOURCE[0]}")/role-map.sh"

generate_routing_from_plan() {
  local slice_dir="$1"
  local now="$2"
  local surface="${3:-agent-loop-cursor}"
  local plan_file="$slice_dir/PLAN.md"
  local out_file="$slice_dir/routing.json"
  local role_map
  role_map="$(role_map_file)"

  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "$role_map" ]]; then
    echo "generate-routing-from-plan: jq and routing-role-map.json required" >&2
    return 1
  fi

  local namespace
  namespace="$(surface_catalog_namespace "$surface")"
  if [[ -z "$namespace" ]]; then
    echo "generate-routing-from-plan: unknown surface: $surface" >&2
    return 1
  fi

  local blast="medium"
  if [[ -f "$plan_file" ]]; then
    if grep -qiE '\*\*HIGH\.\*\*|blast radius.*HIGH' "$plan_file"; then
      blast="high"
    elif grep -qiE '\*\*LOW\.\*\*|blast radius.*LOW' "$plan_file"; then
      blast="low"
    fi
  fi

  local complexity="standard"
  local implement_role="implement-default"
  if [[ "$blast" == "high" ]]; then
    complexity="elevated"
    implement_role="plan-tier"
  fi

  local surface_class tool
  surface_class="$(surface_alias_field "$surface" "surfaceClass")"
  tool="$(surface_alias_field "$surface" "tool")"

  jq -n \
    --arg now "$now" \
    --arg blast "$blast" \
    --arg complexity "$complexity" \
    --arg implementRole "$implement_role" \
    --arg namespace "$namespace" \
    --arg surface "$surface" \
    --arg surfaceClass "$surface_class" \
    --arg tool "$tool" \
    --argjson map "$(cat "$role_map")" \
    '{
    _schema_version: "1",
    _doc: "Generated deterministically from PLAN blast radius — refine via docs/model-routing/router-pass.md",
    generatedAt: $now,
    complexityTier: $complexity,
    blastRadius: $blast,
    orchestrationMode: "autonomous-ready",
    apiPoolBudget: "normal",
    phases: [
      {
        phase: 1,
        stage: "implement",
        surfaceClass: $surfaceClass,
        surface: $surface,
        tool: $tool,
        catalogNamespace: $namespace,
        catalogModelId: $map.roles[$namespace][$implementRole].catalogModelId,
        roleHint: $implementRole,
        pool: $map.roles[$namespace][$implementRole].pool,
        variant: ($map.roles[$namespace][$implementRole].variant // ""),
        catalogFetchedAt: $now,
        verify: {
          stage: "verify",
          surfaceClass: "interactive",
          tool: $tool,
          catalogNamespace: $namespace,
          catalogModelId: $map.roles[$namespace]["verify-tier"].catalogModelId,
          roleHint: "verify-tier",
          pool: $map.roles[$namespace]["verify-tier"].pool,
          variant: ($map.roles[$namespace]["verify-tier"].variant // "")
        },
        basis: "PLAN blast-radius heuristic"
      }
    ]
  }' >"$out_file"
}
