# Agent loop Codex notes

Follow root `AGENTS.md` first. Implement-only headless loop under `tools/agent-loop/`.

## Required context

- Operator runbook: `tools/agent-loop/README.md`
- Architecture: `tools/agent-loop/ARCHITECTURE.md`
- Headless CLI authority (AFK pools): `tools/agent-loop/headless-cli-authority.md`
- Sandcastle comparison (future analysis): `tools/agent-loop/sandcastle-comparison.md`
- Prompt checklist: `tools/agent-loop/prompt-authoring.md`
- Repo convention (opt-in): `docs/agent-loop/agent-loop.md`

## Rules

- Tool stays convention-neutral: bind-mount + prompt + completion count. No PLAN or issue parsing in orchestrator code.
- Prompt files use `.prompt.md` (Markdown body is passed verbatim to the agent CLI).
- Adapter argv changes require Tier-0 `--help` verification in the built pool image (`headless-cli-authority.md`).

## Verification

```bash
cd tools/agent-loop && npm test && npm run lint && npm run build
npm run verify:local
bash scripts/preflight-pool.sh --all
bash tools/agent-loop/prepare-workspace.test.sh
```

Shell tests under `tools/agent-loop/scripts/*.test.sh` and `prepare-workspace.test.sh` are run explicitly (not discovered by `tools/shell-test-runner/` — package-local harness).
