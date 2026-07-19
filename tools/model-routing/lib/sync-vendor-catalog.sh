#!/usr/bin/env bash
# shellcheck shell=bash
# Shared vendor catalog sync implementation (private).

set -uo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=catalog-namespace.sh
source "$(dirname "${BASH_SOURCE[0]}")/catalog-namespace.sh"
# shellcheck source=fetch-doc.sh
source "$(dirname "${BASH_SOURCE[0]}")/fetch-doc.sh"
# shellcheck source=parse-pricing-table.sh
source "$(dirname "${BASH_SOURCE[0]}")/parse-pricing-table.sh"
# shellcheck source=build-catalog-from-registry.sh
source "$(dirname "${BASH_SOURCE[0]}")/build-catalog-from-registry.sh"

_collect_cli_slugs() {
  local namespace="$1"
  local list_cmd
  local line_pattern
  list_cmd="$(namespace_config_field "$namespace" "listModelsCommand")"
  line_pattern="$(namespace_config_field "$namespace" "listModelsLinePattern")"

  if [[ -z "$list_cmd" ]]; then
    echo "[]"
    return 0
  fi

  local -a slugs=()
  if [[ -n "$line_pattern" ]]; then
    mapfile -t slugs < <(bash -c "$list_cmd" 2>/dev/null | grep -E "$line_pattern" || true)
  else
    mapfile -t slugs < <(bash -c "$list_cmd" 2>/dev/null || true)
  fi

  if ((${#slugs[@]} == 0)); then
    echo "[]"
    return 0
  fi

  printf '%s\n' "${slugs[@]}" | jq -R . | jq -s .
}

sync_vendor_catalog() {
  local namespace="$1"
  local force="${2:-false}"
  local check_drift="${3:-false}"
  local dry_run="${4:-false}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "sync-vendor-catalog: jq required" >&2
    return 2
  fi

  local registry_file catalog_file meta_file
  registry_file="$(registry_file_for_namespace "$namespace")" || {
    echo "sync-vendor-catalog: unknown namespace: $namespace" >&2
    return 2
  }
  catalog_file="$(catalog_file_for_namespace "$namespace")"
  meta_file="$(meta_file_for_namespace "$namespace")"

  if [[ -z "$catalog_file" ]]; then
    echo "sync-vendor-catalog: namespace $namespace has no catalog cache (registry-only)" >&2
    return 2
  fi

  if [[ "$force" != true ]] && model_routing_cache_is_fresh "$meta_file" && [[ -f "$catalog_file" ]]; then
    return 0
  fi

  if [[ ! -f "$registry_file" ]]; then
    echo "sync-vendor-catalog: missing registry: $registry_file" >&2
    return 2
  fi

  local now pricing_url pricing_hash pricing_md=""
  now="$(model_routing_iso_now)"
  pricing_url="$(jq -r '.pricingIndexUrl // empty' "$registry_file")"

  if [[ -n "$pricing_url" ]]; then
    pricing_md="$(fetch_doc_url "$pricing_url")" || return 2
    pricing_hash="$(printf '%s' "$pricing_md" | sha256sum 2>/dev/null | awk '{print $1}' \
      || printf '%s' "$pricing_md" | shasum -a 256 | awk '{print $1}')"
    local parse_count
    parse_count="$(printf '%s' "$pricing_md" | parse_pricing_model_ids | wc -l | tr -d ' ')"
    if [[ "$parse_count" -eq 0 ]]; then
      echo "sync-vendor-catalog: low parse confidence for $namespace pricing table" >&2
    fi
  else
    pricing_hash="$(sha256sum "$registry_file" 2>/dev/null | awk '{print $1}' \
      || shasum -a 256 "$registry_file" | awk '{print $1}')"
  fi

  local cli_slugs_json
  cli_slugs_json="$(_collect_cli_slugs "$namespace")"

  local catalog_doc
  catalog_doc="$(build_catalog_from_registry "$registry_file" "$cli_slugs_json" "$now" "$pricing_url" "$pricing_hash")" || return 2

  local meta_doc
  meta_doc="$(jq -n --arg fetchedAt "$now" --arg hash "$pricing_hash" '{fetchedAt: $fetchedAt, contentHash: $hash}')"

  if [[ "$dry_run" == true ]]; then
    echo "$catalog_doc"
    return 0
  fi

  if [[ "$check_drift" == true && -f "$catalog_file" ]]; then
    local old_hash
    old_hash="$(jq -r '.contentHash // .pricingContentHash // empty' "$meta_file" 2>/dev/null)"
    if [[ -n "$old_hash" && "$old_hash" != "$pricing_hash" ]]; then
      echo "sync-vendor-catalog: drift detected for $namespace" >&2
      return 1
    fi
    return 0
  fi

  mkdir -p "$(dirname "$catalog_file")"
  printf '%s\n' "$catalog_doc" >"$catalog_file"
  printf '%s\n' "$meta_doc" >"$meta_file"
  return 0
}
