#!/usr/bin/env bash
# shellcheck shell=bash
# Role-map and surface alias lookups (private).

set -uo pipefail

# shellcheck source=catalog-namespace.sh
source "$(dirname "${BASH_SOURCE[0]}")/catalog-namespace.sh"

role_map_file() {
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/routing-role-map.json"
}

role_map_lookup() {
  local namespace="$1"
  local role_hint="$2"
  local field="$3"
  local map_file
  map_file="$(role_map_file)"
  if [[ ! -f "$map_file" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  jq -r --arg ns "$namespace" --arg role "$role_hint" --arg field "$field" \
    '.roles[$ns][$role][$field] // empty' "$map_file"
}

complexity_fallback_role() {
  local tier="$1"
  local map_file
  map_file="$(role_map_file)"
  jq -r --arg tier "$tier" '.complexityFallback[$tier] // empty' "$map_file" 2>/dev/null
}

surface_catalog_namespace() {
  local surface="$1"
  local map_file
  map_file="$(role_map_file)"
  jq -r --arg surface "$surface" '.surfaceAliases[$surface].catalogNamespace // empty' "$map_file" 2>/dev/null
}

surface_sync_script() {
  local surface="$1"
  local map_file
  map_file="$(role_map_file)"
  jq -r --arg surface "$surface" '.surfaceAliases[$surface].syncScript // empty' "$map_file" 2>/dev/null
}

surface_alias_field() {
  local surface="$1"
  local field="$2"
  local map_file
  map_file="$(role_map_file)"
  jq -r --arg surface "$surface" --arg field "$field" '.surfaceAliases[$surface][$field] // empty' "$map_file" 2>/dev/null
}
