# Model routing (tools slice)

Owner: medley platform tooling. Architecture: `docs/model-routing/architecture.md`. Policy SSOT: `docs/model-routing/policy.md` — cite by heading.

## Contract surfaces

| Entry | Purpose |
| --- | --- |
| `route-for-surface.sh` | Pit-of-success facade (AFK default) |
| `sync-cursor-catalog.sh` | Cursor catalog → gitignored cache |
| `sync-codex-catalog.sh` | Codex catalog → gitignored cache |
| `apply-routing.sh` | `routing.json` + cache → native config |

Private: `lib/`, `cache/` — no external path cites.

## Namespace config

`catalog-namespaces.json` maps each `catalogNamespace` to registry file, cache path, and optional Tier-0 `listModelsCommand`.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `MODEL_ROUTING_CATALOG_TTL_HOURS` | `0` | Cache TTL; `0` = always sync |
| `MODEL_ROUTING_FIXTURE_DIR` | unset | Test fixture root (pricing snippet) |

## Consumers

- `docs/model-routing/README.md` — operator hub
- `docs/model-routing/router-pass.md` — manifest authoring (tool-neutral)
- `tools/agent-loop/` — reads `run.local.json` only

Verification:

```bash
bash tools/model-routing/sync-cursor-catalog.test.sh
bash tools/model-routing/sync-codex-catalog.test.sh
bash tools/model-routing/apply-routing.test.sh
bash tools/model-routing/route-for-surface.test.sh
```
