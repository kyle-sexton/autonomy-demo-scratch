# Claude headless agent-loop — compliance posture

Automation account: **personal automation account** (Max subscription; routines, code reviews, agent-loop only).

## Posture summary

| Posture | Allowed? | Authority |
| --- | --- | --- |
| Third-party harness (OpenClaw, etc.) on subscription OAuth | **No** | [legal-and-compliance](https://code.claude.com/docs/en/legal-and-compliance) |
| Agent SDK library product for other users on subscription OAuth | **No** | [agent-sdk/overview](https://code.claude.com/docs/en/agent-sdk/overview) |
| Official `claude -p` + `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` on your account | **Documented** — residual Consumer Terms §7 ambiguity | [authentication](https://code.claude.com/docs/en/authentication) |
| agent-loop spawning official `claude` binary, personal workspace, per-developer `.env` token | **Conditional** — operator accepts residual risk below | This file |

Billing: cite [`docs/claude-code/rate-limit-reference.md`](../../../docs/claude-code/rate-limit-reference.md) "Agent SDK and claude -p subscription billing" — split postponed; programmatic use on subscription limits today.

## Operator mitigations (required)

1. Personal automation account only — not multi-tenant; not offering Claude to others.
2. `claude setup-token` on host while logged into that automation account; store in `tools/agent-loop/.env` only (`CLAUDE_CODE_OAUTH_TOKEN`); never commit.
3. Never set `ANTHROPIC_API_KEY` in the same environment as Claude pool runs.
4. Low iteration caps during smoke; spend attestation + dashboard canary before enablement.
5. If ban risk is unacceptable: pause credentialed runs and contact Anthropic ([legal-and-compliance](https://code.claude.com/docs/en/legal-and-compliance) "contact sales").

## Operator sign-off (required before Phase 1b credentialed Tier-0 or regression smoke)

- [ ] I accept residual ban risk for subscription OAuth + orchestrated `claude -p` on my automation account, **or** I have written Anthropic confirmation.
- [ ] Token is in gitignored `tools/agent-loop/.env` only; not shared with other developers via repo.
- [ ] I have completed dashboard canary and recorded `operator/spend-safety-attestation-claude.json`.

Signed: _________________  Date: _________

## External authority

- [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)
- [authentication](https://code.claude.com/docs/en/authentication)
- [headless](https://code.claude.com/docs/en/headless)
- [legal-and-compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [permissions](https://code.claude.com/docs/en/permissions)
- [cli-reference](https://code.claude.com/docs/en/cli-reference)
