# Operator-local files

Machine-local attestation and secrets for `tools/agent-loop/`. Nothing here is committed except the example template.

## Spend-safety attestation

Before any credentialed autonomous run, a **human** confirms subscription-only billing with hard spend caps on the vendor dashboard, runs one canary invocation, then records attestation JSON.

| Pool | File (gitignored) |
|------|-------------------|
| `cursor-default` | `spend-safety-attestation-cursor.json` (copy `spend-safety-attestation.example.json`) |
| `claude-default` | `spend-safety-attestation-claude.json` (see `spend-safety-attestation-claude.example.json`) |
| `codex-default` | `spend-safety-attestation-codex.json` (see `spend-safety-attestation-codex.example.json`) |
| `grok-default` | `spend-safety-attestation-grok.json` (see `spend-safety-attestation-grok.example.json`) |

Copy `spend-safety-attestation.example.json`, set both booleans to `true`, add `confirmedAt` and matching `pool`. The orchestrator **reads only** — it never writes these files.

Full checklist: `tools/agent-loop/README.md` "Spend safety" and `context/spend-safety.md`.

## Headless autonomous privilege

Cursor and Claude adapters run headless with full-auto permission modes inside credentialed containers (`cursor-agent --force`; `claude --permission-mode bypassPermissions` with `--max-turns` / `--max-budget-usd` caps). That is **high privilege** — the spend gate and pool attestation exist because these runs can mutate the bind-mounted workspace and call vendor APIs. Do not point autonomous loops at workspaces you are unwilling to lose; use dry-run prompts and low iteration caps when validating a new pool image or prompt.

## Claude OAuth setup

1. Log into Claude Code on the host with the automation subscription account.
2. Run `claude setup-token` and copy the token into `tools/agent-loop/.env` as `CLAUDE_CODE_OAUTH_TOKEN=` (never commit).
3. Ensure `ANTHROPIC_API_KEY` is **unset** in the same shell — subscription override risk.
