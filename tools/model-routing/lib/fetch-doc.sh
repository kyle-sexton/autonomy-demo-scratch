#!/usr/bin/env bash
# shellcheck shell=bash
# Fetch a URL to stdout. Uses curl when available.

set -uo pipefail

fetch_doc_url() {
  local url="$1"
  if [[ -n "${MODEL_ROUTING_FIXTURE_DIR:-}" && -f "${MODEL_ROUTING_FIXTURE_DIR}/pricing-snippet.md" && "$url" == *models-and-pricing* ]]; then
    cat "${MODEL_ROUTING_FIXTURE_DIR}/pricing-snippet.md"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "model-routing: curl required to fetch $url" >&2
    return 1
  fi
  curl -fsSL --max-time 30 "$url"
}
