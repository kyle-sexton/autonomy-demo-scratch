# Headless CLI authority (agent-loop)

Link hub for **non-interactive (AFK)** agent-loop pools. Medley adapter paths and flags live beside **authoritative upstream docs** — verify flags with `docker run … <binary> --help` in the built image before changing adapters.

Interactive session tools (`/goal`, Codex plugin) are documented in [`docs/agent-loop/loop-primitives.md`](../../docs/agent-loop/loop-primitives.md) "Interactive vs non-interactive".

## Pool tiers (AFK)

| Tier | Pool id | Image | Status |
| ---- | ------- | ----- | ------ |
| 1 — Primary | `cursor-default` | `agent-loop-cursor:thin` | Default |
| 2 — Optional | `codex-default` | `agent-loop-codex:thin` | Enable in `pools.local.jsonc` |
| 3 — Optional | `claude-default` | `agent-loop-claude:thin` | Enable in `pools.local.jsonc` after tier-0 + attestation |
| 4 — Optional | `grok-default` | `agent-loop-grok:thin` | Enable in `pools.local.jsonc` |

**Naming note:** Older pool ids used `*-phase1` (internal roadmap milestone labels). Renamed for semantic clarity — `phase` in slice `PLAN.md` means slice work, not pool generation.

**Operator migration:** update gitignored `pools.local.jsonc` pool keys and attestation `"pool"` field to match `gatePoolId` in [`src/agent-pool.ts`](src/agent-pool.ts).

## Tier-0 workflow (all pools)

1. Build image (`docker/<cli>/Dockerfile`).
2. `bash scripts/validate-pool-cli.sh` (no credentials).
3. `docker run --rm <image> <binary> --help` — adapter flags must match.
4. Spend-gated write probe: `pool-gates/*-write.sh` per pool.
5. Operator readiness: `bash scripts/preflight-pool.sh --pool <pool-id>` (safe) or `--tier0` (credentialed).

## Enable checklist (per pool)

1. Build image.
2. Run `validate-pool-cli.sh`.
3. Complete spend-safety dashboard canary for that vendor.
4. Write `operator/spend-safety-attestation-<cli>.json` (copy `operator/spend-safety-attestation.example.json`).
5. Set `"enabled": true` for the pool in `pools.local.jsonc` (tier 2+).

---

## Cursor — tier 1 (`cursor-default`)

| Item | Value |
| ---- | ----- |
| Image | `agent-loop-cursor:thin` |
| Binary | `cursor-agent` |
| Auth env | `CURSOR_API_KEY` (subscription User API Key) |
| Attestation | `operator/spend-safety-attestation-cursor.json` |
| Adapter | [`src/adapters/cursor.ts`](src/adapters/cursor.ts) |
| Model table | [`src/model-profiles/cursor.ts`](src/model-profiles/cursor.ts) |
| `inContainerHooks` | `suppressed` — [`pool-session-bind-mounts/cursor.ts`](src/pool-session-bind-mounts/cursor.ts) |

**Official authority:** [CLI headless](https://cursor.com/docs/cli/headless.md), [parameters](https://cursor.com/docs/cli/reference/parameters.md), [output-format](https://cursor.com/docs/cli/reference/output-format.md). Medley cross-link: [`docs/cursor/cli.md`](../../docs/cursor/cli.md). IDE terminal sandbox / Run Mode applies to **host** orchestrator launch only — not in-container iterations: [`README.md`](README.md) "Cursor IDE terminal (host launch only)".

**Tier-0 gate:** `bash scripts/pool-gates/cursor-write.sh`

---

## Codex — tier 2 (`codex-default`)

| Item | Value |
| ---- | ----- |
| Image | `agent-loop-codex:thin` |
| Binary | `codex` |
| Auth | bind-mount `~/.codex/auth.json` → `/var/codex-home/auth.json`; `CODEX_HOME=/var/codex-home` (outside workspace) — never `OPENAI_API_KEY` / `CODEX_API_KEY` |
| Attestation | `operator/spend-safety-attestation-codex.json` |
| Adapter | [`src/adapters/codex.ts`](src/adapters/codex.ts) |
| Output parser | [`src/output-parsers/codex-json.ts`](src/output-parsers/codex-json.ts) (`exec --json`) |
| `inContainerHooks` | `none` |

**Official authority:** [Codex CLI](https://developers.openai.com/codex/), [config reference](https://developers.openai.com/codex/config-reference/). Medley cross-link: [`docs/codex/README.md`](../../docs/codex/README.md). **Interactive** Codex plugin (Profile C): [`docs/codex/codex-delegation.md`](../../docs/codex/codex-delegation.md) — not this AFK harness.

**Pool gates:** `bash scripts/pool-gates/codex-write.sh` (container write, spend-gated). Pool stays **disabled by default** in `pools.example.jsonc`.

Build: `docker build -t agent-loop-codex:thin -f docker/codex/Dockerfile .`

---

## Claude — tier 3 (`claude-default`)

| Item | Value |
| ---- | ----- |
| Image | `agent-loop-claude:thin` |
| Binary | `claude` |
| Auth env | `CLAUDE_CODE_OAUTH_TOKEN` in gitignored `tools/agent-loop/.env` — from `claude setup-token`; never `ANTHROPIC_API_KEY` |
| Attestation | `operator/spend-safety-attestation-claude.json` |
| Adapter | [`src/adapters/claude.ts`](src/adapters/claude.ts) |
| Config lock | [`src/claude-headless-config.ts`](src/claude-headless-config.ts) |
| Permission probe (operator) | `AGENT_LOOP_CLAUDE_PERMISSION_PROBE` — `scripts/pool-gates/claude-permission-probe.sh` |
| `inContainerHooks` | `native` — medley `.claude/hooks/*` (image includes `jq`) |

**Official authority:** [Headless / `-p`](https://code.claude.com/docs/en/headless), [cli-reference](https://code.claude.com/docs/en/cli-reference), [permissions](https://code.claude.com/docs/en/permissions). Billing posture: [`rate-limit-reference.md`](../../docs/claude-code/rate-limit-reference.md) "Agent SDK and claude -p subscription billing". Compliance: [`context/compliance-posture.md`](context/compliance-posture.md).

### Adapter flags (locked)

```bash
claude -p \
  --permission-mode bypassPermissions \
  --no-session-persistence \
  --output-format stream-json \
  --max-turns 40 \
  --max-budget-usd 2 \
  [--model <slug>] \
  "<prompt>"
```

Re-test `dontAsk` when `permissions.allow` covers implement prompts; prefer strictest mode that passes Tier-0. Never `--bare` with subscription OAuth ([authentication](https://code.claude.com/docs/en/authentication)).

**Hooks:** Unlike Cursor (`inContainerHooks: suppressed`), Claude pool keeps **native** hooks — official `claude` CLI is the hook host. Cursor suppression exists because `cursor-agent` headless hits hook transport failures, not because medley hooks are unwanted for Claude.

**Tier-0 gate:** `bash scripts/pool-gates/claude-write.sh`

Build: `cd tools/agent-loop && docker build -t agent-loop-claude:thin -f docker/claude/Dockerfile .`

---

## Grok — tier 4 (`grok-default`)

| Item | Value |
| ---- | ----- |
| Image | `agent-loop-grok:thin` |
| Binary | `grok` |
| Auth | bind-mount `~/.grok/auth.json` → `/var/grok-home/auth.json`; `GROK_HOME=/var/grok-home` (outside workspace) — never `XAI_API_KEY` |
| Attestation | `operator/spend-safety-attestation-grok.json` |
| Adapter | [`src/adapters/grok.ts`](src/adapters/grok.ts) |
| Model table | [`src/model-profiles/grok.ts`](src/model-profiles/grok.ts) |
| `inContainerHooks` | `none` |

**Official authority:** [Grok Build overview](https://docs.x.ai/build/overview), [headless scripting](https://docs.x.ai/build/cli/headless-scripting). Medley cross-link: [`docs/grok-build/README.md`](../../docs/grok-build/README.md).

**Pool gates:** `bash scripts/pool-gates/grok-write.sh` (container write, spend-gated), `bash tools/grok-build/record-host-smoke.sh` (host smoke). Pool stays **disabled by default** — Grok is optional; enable only when installed and attested.

Build: `docker build -t agent-loop-grok:thin -f docker/grok/Dockerfile .`

---

## Subscription compliance (Claude pool)

Cite only: [`context/compliance-posture.md`](context/compliance-posture.md) — operator sign-off before credentialed spend.

---

## Spend safety

Per-pool attestation: [`context/spend-safety.md`](context/spend-safety.md), [`README.md`](README.md) "Spend safety".
