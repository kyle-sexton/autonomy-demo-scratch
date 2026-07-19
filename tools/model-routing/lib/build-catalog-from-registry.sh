#!/usr/bin/env bash
# shellcheck shell=bash
# Build catalog JSON from a vendor registry + optional live CLI slugs (private).

set -uo pipefail

build_catalog_from_registry() {
  local registry_file="$1"
  local cli_slugs_json="$2"
  local fetched_at="$3"
  local pricing_url="${4:-}"
  local pricing_hash="${5:-}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "build-catalog-from-registry: jq required" >&2
    return 1
  fi

  jq -n \
    --arg fetchedAt "$fetched_at" \
    --arg pricingUrl "$pricing_url" \
    --arg pricingHash "$pricing_hash" \
    --argjson registry "$(cat "$registry_file")" \
    --argjson cli "$cli_slugs_json" \
    '
    ($registry.models // []) as $models |
    ($models | map({
      key: .modelId,
      value: (
        . as $m |
        ($cli | map(select(test($m.cliSlugMatch; "i")))) as $matches |
        {
          docUrl: ($m.docUrl // ""),
          pool: $m.pool,
          defaultSlug: (
            if ($matches | length) > 0 then $matches[0]
            elif ($m.defaultSlug // "") != "" then $m.defaultSlug
            else $m.modelId end
          ),
          cliSlugs: $matches
        }
      )
    }) | from_entries) as $catalogModels |
    {
      fetchedAt: $fetchedAt,
      pricingIndexUrl: (if $pricingUrl != "" then $pricingUrl else null end),
      pricingContentHash: (if $pricingHash != "" then $pricingHash else null end),
      pools: (
        $models
        | group_by(.pool)
        | map({key: .[0].pool, value: map(.modelId)})
        | from_entries
      ),
      models: $catalogModels
    }
    '
}
