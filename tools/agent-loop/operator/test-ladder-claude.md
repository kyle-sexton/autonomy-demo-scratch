# Claude headless pool — full test ladder

Operator runbook for `claude-default` in agent-loop. Structural steps need no subscription spend; credentialed steps require compliance sign-off.

## Prerequisites (all tiers)

| Requirement | Check |
| --- | --- |
| Git Bash (Windows) | Hooks and pool gates use bash |
| Node ≥ 24 | `fnm use` / `.nvmrc` |
| Docker | `docker info` succeeds |
| .NET SDK 10 | `dotnet sdk check` (repo work only) |
| `jq` | `tools/bootstrap.sh` |
| Repo bootstrap | `bash tools/bootstrap.sh` from repo root |

## Prerequisites (credentialed tiers only)

| Requirement | Notes |
| --- | --- |
| Automation account | **personal automation account** — routines / agent-loop only |
| Host Claude CLI | `claude --version` (for `claude setup-token`) |
| Compliance sign-off | [`context/compliance-posture.md`](../context/compliance-posture.md) checkbox |
| OAuth token | `claude setup-token` → `tools/agent-loop/.env` as `CLAUDE_CODE_OAUTH_TOKEN=` |
| No metered key | `ANTHROPIC_API_KEY` **unset** in OS env and `.env` |
| Attestation | Copy `operator/spend-safety-attestation-claude.example.json` → `operator/spend-safety-attestation-claude.json` |
| Pool enablement | `cp pools.example.jsonc pools.local.jsonc` — set `claude-default.enabled: true` |
| Claude image | `docker build -t agent-loop-claude:thin -f docker/claude/Dockerfile .` from `tools/agent-loop` |

---

## Tier A — structural (no credentials, every PR)

From `tools/agent-loop`:

```bash
bash scripts/preflight-pool.sh --pool claude-default    # safe rollup (no subscription spend)
npm run lint
npm test                    # vitest + verify:structural
npm run verify:local        # lint + test + validate-pool-cli (skips missing images)
```

Or individually:

```bash
npm run build
bash scripts/verify-claude-headless-writes.test.sh
bash scripts/validate-pool-cli.sh    # needs agent-loop-claude:thin image
bash prepare-workspace.test.sh       # from tools/agent-loop
```

**Pass criteria:** all tests green; structural script reports native hooks + zero Claude session bind mounts.

---

## Tier B — image + CLI binary (no subscription spend)

```bash
cd tools/agent-loop
docker build -t agent-loop-claude:thin -f docker/claude/Dockerfile .
bash scripts/validate-pool-cli.sh
docker run --rm agent-loop-claude:thin claude --version   # expect 2.1.178 (Dockerfile ARG)
docker run --rm agent-loop-claude:thin jq --version
```

**Pass criteria:** pinned CLI version matches `docker/claude/Dockerfile` `CLAUDE_CLI_VERSION`.

---

## Tier C — credentialed tier-0 write (subscription spend)

After Tier A–B pass and all credentialed prerequisites above:

```bash
cd tools/agent-loop
# Confirm token loads (prints HAS_TOKEN)
node --input-type=module -e "
  import { loadProjectEnv } from './build/env.js';
  loadProjectEnv(process.cwd());
  console.log(process.env.CLAUDE_CODE_OAUTH_TOKEN?.trim() ? 'HAS_TOKEN' : 'NO_TOKEN');
"

bash scripts/pool-gates/claude-write.sh
```

**Pass criteria:** `verify-claude-headless-writes: PASS`; probe file `out/headless-claude-tier0.probe` contains `TIER0_OK`; no `hook blocked` in output.

---

## Tier D — permission matrix (optional, subscription spend)

Compare unattended modes before locking `dontAsk` in `claude-headless-config.ts`:

```bash
cd tools/agent-loop
bash scripts/pool-gates/claude-permission-probe.sh
```

Uses `AGENT_LOOP_CLAUDE_PERMISSION_PROBE` (`dontAsk`, `bypassPermissions`, `auto`). Record which modes pass without hang; update `flag-matrix.md` and config if promoting `dontAsk`.

---

## Tier E — regression smoke E2E

From `tools/agent-loop` with pool enabled and attestation on disk:

```bash
AGENT_LOOP_POOL=claude-default AGENT_LOOP_MODEL=claude-sonnet-4-6 \
  node build/orchestrator.js 2 examples/regression-smoke/implement.prompt.md 1 examples/regression-smoke
```

See `examples/regression-smoke/README.md` for expected artifacts.

**Pass criteria:** orchestrator completes; smoke slice file updated as prompt specifies.

---

## Tier F — host boundary audit (after any container run)

```bash
bash scripts/check-host-container-env-boundary.sh
```

**Pass criteria:** exit 0 — no `CLAUDE_PROJECT_DIR=/workspace` or `core.worktree` leaks on host.

---

## Record outcome

Record tier pass/fail in your active work slice `verify/` journal or operator notes with proof per step.
