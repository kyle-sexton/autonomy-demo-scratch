#!/usr/bin/env bash
# shellcheck shell=bash
# Namespace config lookups (private).

set -uo pipefail

_catalog_namespace_unit_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

model_routing_namespaces_file() {
  echo "$(_catalog_namespace_unit_root)/catalog-namespaces.json"
}

namespace_config_field() {
  local namespace="$1"
  local field="$2"
  local config_file
  config_file="$(model_routing_namespaces_file)"
  if [[ ! -f "$config_file" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  jq -r --arg ns "$namespace" --arg field "$field" '.[$ns][$field] // empty' "$config_file"
}

catalog_file_for_namespace() {
  local namespace="$1"
  local rel
  rel="$(namespace_config_field "$namespace" "catalogFile")"
  if [[ -z "$rel" ]]; then
    echo ""
    return 0
  fi
  if [[ -n "${MODEL_ROUTING_CACHE_DIR:-}" ]]; then
    echo "${MODEL_ROUTING_CACHE_DIR}/$(basename "$rel")"
    return 0
  fi
  echo "$(_catalog_namespace_unit_root)/$rel"
}

registry_file_for_namespace() {
  local namespace="$1"
  local rel
  rel="$(namespace_config_field "$namespace" "registryFile")"
  if [[ -z "$rel" ]]; then
    echo ""
    return 1
  fi
  echo "$(_catalog_namespace_unit_root)/$rel"
}

meta_file_for_namespace() {
  local namespace="$1"
  local rel
  rel="$(namespace_config_field "$namespace" "metaFile")"
  if [[ -z "$rel" ]]; then
    echo ""
    return 0
  fi
  if [[ -n "${MODEL_ROUTING_CACHE_DIR:-}" ]]; then
    echo "${MODEL_ROUTING_CACHE_DIR}/$(basename "$rel")"
    return 0
  fi
  echo "$(_catalog_namespace_unit_root)/$rel"
}
