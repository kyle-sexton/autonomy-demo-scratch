#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for tools/model-routing/ (private — no external cites).

set -uo pipefail

model_routing_unit_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

model_routing_repo_root() {
  git -C "$(model_routing_unit_root)" rev-parse --show-toplevel 2>/dev/null \
    || dirname "$(model_routing_unit_root)"
}

model_routing_cache_is_fresh() {
  local meta_file="$1"
  local ttl_hours="${MODEL_ROUTING_CATALOG_TTL_HOURS:-0}"
  if [[ ! -f "$meta_file" ]]; then
    return 1
  fi
  if [[ "$ttl_hours" == "0" || "$ttl_hours" == "0.0" ]]; then
    return 1
  fi
  local fetched_at
  fetched_at="$(grep -E '"fetchedAt"' "$meta_file" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')"
  if [[ -z "$fetched_at" ]]; then
    return 1
  fi
  local now_epoch fetched_epoch
  now_epoch="$(date -u +%s)"
  if date -u -d "$fetched_at" +%s >/dev/null 2>&1; then
    fetched_epoch="$(date -u -d "$fetched_at" +%s)"
  else
    fetched_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$fetched_at" +%s 2>/dev/null || echo 0)"
  fi
  local age_hours=$(((now_epoch - fetched_epoch) / 3600))
  [[ "$age_hours" -lt "$ttl_hours" ]]
}

model_routing_iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}
