# Regression smoke — agent-loop

Isolated bind-mount workspace for credentialed regression without touching repo source.

## What this proves

| Facet | How |
|-------|-----|
| Scoped workspace bind-mount | Orchestrator mounts this directory only |
| Tier-0 completion | Orchestrator counts `out/regression-ok.txt` |
| Prompt + sentinel | Agent writes one file, emits `NO_MORE_TASKS` |
| Observability | Check `logs/runs/{timestamp}-regression-smoke/` after run |

Real implement runs mount a full worktree instead.

## Run

```bash
cd tools/agent-loop
rm -f examples/regression-smoke/out/regression-ok.txt
AGENT_LOOP_MODEL=composer-2.5-fast \
  node build/orchestrator.js 2 \
    examples/regression-smoke/implement.prompt.md \
    1 \
    examples/regression-smoke
```

Expect exit 0 and `examples/regression-smoke/out/regression-ok.txt` containing `ok`.

### Claude pool (`claude-default`)

Requires `CLAUDE_CODE_OAUTH_TOKEN` in `tools/agent-loop/.env`, compliance sign-off, and `operator/spend-safety-attestation-claude.json`.

```bash
cd tools/agent-loop
rm -f examples/regression-smoke/out/regression-ok.txt
AGENT_LOOP_POOL=claude-default AGENT_LOOP_MODEL=claude-sonnet-4-6 \
  node build/orchestrator.js 2 \
    examples/regression-smoke/implement.prompt.md \
    1 \
    examples/regression-smoke
```
