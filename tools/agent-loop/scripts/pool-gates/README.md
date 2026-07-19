# Pool acceptance gates

Pre-flight checks before enabling optional agent-loop pools. **Not** slice verify scripts (`verify-phase-N.sh`) and **not** MCP capability tests.

Medley uses **“pool gates”** here — not an xAI term. Each gate answers one question before you enable a pool in `pools.local.jsonc`.

## Dimensions

| Gate | Question | Examples |
| ---- | -------- | -------- |
| **auth** | Subscription credential on host? | `bash tools/grok-build/check-availability.sh` |
| **binary** | Pool image built; CLI runs? | `bash scripts/validate-pool-cli.sh` |
| **write** | Headless agent can edit bind-mounted workspace? | `pool-gates/*-write.sh` |
| **host-smoke** | Optional CLI works outside Docker? | `tools/grok-build/record-host-smoke.sh` |

MCP access, browser capture, and network egress are tested elsewhere.

## Repo mirror pollution (preventive)

After a pool run, tracked mirrors must not gain **runtime** files:

| Path | Action if present |
| ---- | ----------------- |
| `<repo>/.grok/auth.json`, `sessions/`, `bundled/` | Delete — legacy `GROK_HOME=/workspace` pollution |
| `<repo>/.codex/auth.json`, `sessions/`, `*.sqlite`, `logs/` | Delete — legacy `CODEX_HOME=/workspace/.codex` pollution |

Pools use `/var/grok-home` and `/var/codex-home` so new pollution should not recur. Root `.gitignore` lists surgical runtime patterns — see `docs/grok-build/local-state.md`, `docs/codex/local-state.md`.

## Scripts

| Pool | Write gate | Readiness rollup | Spend attestation required |
| ---- | ---------- | ---------------- | -------------------------- |
| `cursor-default` | [`cursor-write.sh`](cursor-write.sh) | [`preflight-pool.sh --pool cursor-default`](../preflight-pool.sh) | yes |
| `cursor-cloud-parity` | [`cursor-write.sh`](cursor-write.sh) | [`preflight-pool.sh --pool cursor-cloud-parity`](../preflight-pool.sh) | yes |
| `codex-default` | [`codex-write.sh`](codex-write.sh) | [`preflight-pool.sh --pool codex-default`](../preflight-pool.sh) | yes |
| `claude-default` | [`claude-write.sh`](claude-write.sh) | [`preflight-pool.sh --pool claude-default`](../preflight-pool.sh) | yes |
| `claude-default` (permission matrix) | [`claude-permission-probe.sh`](claude-permission-probe.sh) | — | yes — after tier-0 passes |
| `grok-default` | [`grok-write.sh`](grok-write.sh) | [`preflight-pool.sh --pool grok-default`](../preflight-pool.sh) | yes |
| All pools | — | [`preflight-pool.sh --all`](../preflight-pool.sh) | per pool |

## Windows (Git Bash)

Shell gates source [`../lib/docker-git-bash.sh`](../lib/docker-git-bash.sh). The Node orchestrator normalizes bind-mount paths via `src/docker-host-path.ts`.
