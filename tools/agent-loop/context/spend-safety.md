# Spend safety

Per-pool attestation — subscription-only, hard-capped autonomous runs. Operator files: `operator/README.md`.

## Constraint

**Subscription-billed only — zero on-demand metered spend** for autonomous loops.

## Mechanism (all pools)

1. **Dashboard / account:** confirm hard cap or subscription-only billing for the target tool.
2. **Canary:** one credentialed headless smoke; confirm usage dashboard shows no unexpected on-demand delta.
3. **Attestation:** write the pool-specific gitignored file under `tools/agent-loop/operator/` (copy `operator/spend-safety-attestation.example.json`).
4. **Orchestrator:** `evaluateGateForPool()` refuses credentialed runs without a matching marker (`gate.ts`).

## Auth by pool

| Pool | Subscription path | Never use (metered fallback) |
|------|-------------------|------------------------------|
| Cursor | `CURSOR_API_KEY` env forward | Cloud Agent `&` prefix |
| Claude | `CLAUDE_CODE_OAUTH_TOKEN` env forward | `ANTHROPIC_API_KEY` |
| Codex | bind-mount `~/.codex/auth.json` | `OPENAI_API_KEY`, `CODEX_API_KEY` |

## Operator readiness (all pools)

Safe rollup (no subscription spend unless `--tier0`):

```bash
cd tools/agent-loop
bash scripts/preflight-pool.sh --pool cursor-default
bash scripts/preflight-pool.sh --pool codex-default
bash scripts/preflight-pool.sh --pool claude-default
bash scripts/preflight-pool.sh --pool grok-default
bash scripts/preflight-pool.sh --all
```

Credentialed tier-0 write (spend): append `--tier0` to any command above.

## Claude checklist (tier 3)

1. Confirm Max subscription billing on automation account (no `ANTHROPIC_API_KEY` path).
2. `claude setup-token` on host → `CLAUDE_CODE_OAUTH_TOKEN` in gitignored `tools/agent-loop/.env`.
3. Build image: `docker build -t agent-loop-claude:thin -f docker/claude/Dockerfile .` from `tools/agent-loop/`.
4. Canary: `bash scripts/pool-gates/claude-write.sh` after compliance sign-off ([`context/compliance-posture.md`](compliance-posture.md)).
5. Attestation: `operator/spend-safety-attestation-claude.json` with `"pool": "claude-default"`.
6. Enable `claude-default` in `pools.local.jsonc`.

## Codex checklist (tier 2)

1. Confirm ChatGPT/Codex subscription billing (no API key metered path).
2. Canary: `bash scripts/pool-gates/codex-write.sh` after image build + `~/.codex/auth.json`.
3. Attestation: `operator/spend-safety-attestation-codex.json` with `"pool": "codex-default"`.
4. Enable `codex-default` in `pools.local.jsonc`.

## Cursor checklist (research SSOT)

Full evidence + dashboard steps: `tools/agent-loop/README.md` "Spend safety" — Monthly Limit **Disabled**, On-Demand stays **$0.00** on canary.
