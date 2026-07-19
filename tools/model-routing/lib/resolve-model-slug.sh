#!/usr/bin/env bash
# shellcheck shell=bash
# Resolve catalogModelId + variant to harness-native slug.

set -uo pipefail

# shellcheck source=catalog-namespace.sh
source "$(dirname "${BASH_SOURCE[0]}")/catalog-namespace.sh"

_resolve_from_registry() {
  local registry_file="$1"
  local model_id="$2"

  jq -r --arg id "$model_id" '
    (.models[] | select(.modelId == $id)) as $m |
    if $m == null then empty else ($m.defaultSlug // $m.modelId) end
  ' "$registry_file"
}

resolve_model_slug() {
  local namespace="$1"
  local model_id="$2"
  local variant="${3:-}"
  local catalog_file
  catalog_file="$(catalog_file_for_namespace "$namespace")"

  if [[ -n "$catalog_file" && -f "$catalog_file" ]] && command -v jq >/dev/null 2>&1; then
    local slug
    slug="$(jq -r --arg id "$model_id" --arg v "$variant" '
      (.models[$id] // empty) as $entry |
      if $entry == null then empty
      else
        ($entry.cliSlugs // []) as $slugs |
        if ($v | length) > 0 then
          (($slugs[]? | select(test($v; "i"))) // $entry.defaultSlug // empty)
        else
          ($entry.defaultSlug // empty)
        end
      end
    ' "$catalog_file")"
    if [[ -n "$slug" && "$slug" != "null" ]]; then
      echo "$slug"
      return 0
    fi
  fi

  local registry_file
  registry_file="$(registry_file_for_namespace "$namespace")" || {
    echo "resolve-model-slug: unknown namespace: $namespace" >&2
    return 1
  }

  local fallback_slug
  fallback_slug="$(_resolve_from_registry "$registry_file" "$model_id")"
  if [[ -n "$fallback_slug" && "$fallback_slug" != "null" ]]; then
    echo "$fallback_slug"
    return 0
  fi

  echo "resolve-model-slug: no slug for $model_id in namespace $namespace" >&2
  return 1
}
