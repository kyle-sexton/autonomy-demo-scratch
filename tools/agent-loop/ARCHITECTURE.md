# Agent loop architecture

Design reference for extending the implement-only loop.

## SOLID mapping

| Principle | How it shows up in code |
|-----------|-------------------------|
| **S** — Single responsibility | Each module one reason to change: `session-config` (parse inputs), `gate` (attestation), `preflight/*` (prompt + credential checks), `iteration-runner` (one Docker spawn), `run-loop` (iteration schedule + exit codes only), `adapters/<cli>.ts` (argv), `model-profiles/<cli>.ts` (slug tables), `output-parsers/*` (stream shape), `operator-recovery` (failure hints), pure `sentinel`/`completion` |
| **O** — Open/closed | New CLI = adapter + model-profile + optional preflight checker + pool row + Dockerfile; registries (`selectAdapter`, `resolveModelSlug`, `runIterationPreflight`, `selectOutputParser`) unchanged |
| **L** — Liskov substitution | Any `AgentCliAdapter` / `AgentOutputParser` / `IterationPreflightChecker` must honor its interface contract |
| **I** — Interface segregation | Narrow ports: `RunFilesystem`, `RunConsole`, `ProcessExit`; strategies split by concern in `CliExtensionStrategies` |
| **D** — Dependency inversion | `runAgentLoop({ ports, dependencies })` — loop depends on ports + strategy bundle + `ContainerRuntime`, not concrete registries |

GoF **Adapter** maps `IterationContext` → vendor CLI. No DI container — explicit ports + strategy bundle + defaults.

## GoF patterns and .NET parallels

| Pattern | Where it lives | Open/Closed role |
|---------|----------------|------------------|
| **Adapter** | `adapters/<cli>.ts` | New CLI argv shape without changing orchestrator |
| **Strategy** | `CliExtensionStrategies` (`cli-extensions.ts`) — adapter, model slug, output parser, preflight | Swap algorithms per CLI via registry rows; tests inject doubles via `RunLoopDependencies` |
| **Registry + Strategy** | `selectAdapter`, `resolveModelSlug`, `selectOutputParser`, `runIterationPreflight` | Add row → extend; no `if (cli === …)` in `run-loop.ts` |
| **Abstract Factory** | `createDefaultRunLoopDependencies()` | One factory builds strategies + `ContainerRuntime` for a run |
| **Factory Method** | `createDockerContainerRuntime`, `buildRunSession`, `resolveAgentPool` | Construct complex objects behind stable entry points |
| **Template Method** | `runAgentLoop` iteration skeleton | Fixed schedule (preflight → spawn → parse → decide → exit); steps delegate to strategies |
| **Chain of Responsibility** | Launch checks (today: prompt preflight → credential assert → host-file assert) | Each check is a separate module; future: composable `LaunchPreflightStep[]` |
| **Dependency Inversion** | `RunLoopPorts` + `RunLoopDependencies` | Core depends on `RunFilesystem` / `ContainerRuntime` / strategy interfaces, not `spawn` or vendor parsers |

### Result pattern (railway-oriented — mirrors `Platform.Core.Results.Result`)

Expected failures use `Result<T>` (`src/result.ts`) with `LoopError { exitCode, message }` — not exceptions for control flow.

| TypeScript | .NET parallel | Used for |
|------------|---------------|----------|
| `Result<void>` preflight | `Result` / `Result<Unit>` | Prompt byte budget |
| `GateDecision` | `Result` with domain reason | Spend-safety attestation |
| `SessionBuildResult` | `Result<RunSession>` | Session assembly (candidate for migration) |
| `CompletionResult` | Domain enum + reason string | Post-iteration policy (pure policy object, not transport Result) |

Prefer `Result<T>` when the caller must branch on **expected** failure with an exit code. Reserve exceptions for programmer errors and unexpected I/O.

### SOLID — current posture and next seams

| Principle | Today | Next improvement |
|-----------|-------|------------------|
| **SRP** | Registries split adapter / model / parser / preflight | Split `session-config.ts` composer when it grows |
| **OCP** | New CLI = registry rows + pool row | Codex JSON parser row in `selectOutputParser` when shape is verified |
| **LSP** | All `AgentCliAdapter` / `AgentOutputParser` honor contracts | Document parser contract: sentinel scan text may be empty on truncated streams |
| **ISP** | `RunLoopPorts` trimmed to fs + console + exit (removed unused `ProcessRunner`) | Optional: split `RunFilesystem` read vs write for read-only tests |
| **DIP** | `runAgentLoop({ ports, dependencies })` | Session build could accept `GateEvaluator` port for pure tests |

### Anti-patterns to avoid

- **Switch on `agentCli` in `run-loop.ts`** — belongs in a registry module.
- **Throwing for prompt-too-large / missing creds** — use `Result` + explicit exit.
- **Embedding adapters on pool rows** — use `resolvePoolAdapter` → `selectAdapter` SSOT.
- **God `constants.ts` with vendor literals** — colocate with enforcing module.

## Layering

```text
CLI / env / run.local.json
        ↓  session-config → RunSession
RunSession + AgentPool (cli, image, gate paths — adapter via resolvePoolAdapter)
        ↓  run-loop (ports-injected)
runIterationPreflight → assertCredentialsPresent → iteration-runner → docker run
        ↓  selectOutputParser → sentinel / usage / sidecar
Pure: sentinel, completion, model-profiles, operator-recovery, gate
```

## Per-CLI encapsulation (four parallel extension surfaces)

Vendor-specific knowledge is grouped **by concern + CLI**, not in orchestrator modules:

| Surface | Folder / module | Registry | Owns |
|---------|-----------------|----------|------|
| Container argv | `adapters/<cli>.ts` | `selectAdapter` | Flags, env var names |
| Model slugs | `model-profiles/<cli>.ts` | `resolveModelSlug` | Role/effort tables |
| Prompt preflight | `preflight/<cli>-*.ts` | `runIterationPreflight` | Byte budgets, shape checks |
| Output parsing | `output-parsers/*.ts` | `selectOutputParser` | NDJSON result events, sidecars |
| Session bind mounts | `pool-session-bind-mounts/<cli>.ts` | `resolvePoolSessionBindMounts` | Per-pool container-only overrides (e.g. hook suppression) |
| Pool metadata | `agent-pool.ts` rows | `resolveAgentPool` | Image, gate path, `inContainerHooks`, credential mounts |

| Orchestrator-only | Module | Owns |
|-------------------|--------|------|
| Limits + exit codes | `constants.ts` | Timeouts, labels, exit 7 — no vendor literals |
| Credential env | `preflight/credentials.ts` | Adapter-declared env + pool host paths |

`agent-pool.ts` stores **pool rows only** — adapters resolve through `resolvePoolAdapter` → `selectAdapter` (single SSOT). Gate marker paths live on pool rows, not in `spend-safety-attestation.ts`.

No barrel `index.ts` files (repo lint). Import registry modules directly (`resolve.js`, `select.js`, `run-iteration-preflight.js`).

**Do not** create `constants/cursor/` for one or two literals — colocate beside the enforcing module (`preflight/cursor-prompt-budget.ts`).

## Multi-CLI extensibility (Cursor, Claude, Codex, future)

Each new CLI:

1. `adapters/<cli>.ts` — register in `selectAdapter`
2. `model-profiles/<cli>.ts` — register in `resolveModelSlug`
3. Optional `preflight/<cli>-*.ts` — register in `runIterationPreflight`
4. Optional output parser — register in `selectOutputParser` when stream shape differs
5. `AgentPool` row in `agent-pool.ts` (image, gate path, default mounts)
6. `docker/<cli>/Dockerfile`

`run-loop.ts` must not import vendor modules directly.

## Docker images — one per CLI

| Image tag | Contents |
|-----------|----------|
| `agent-loop-cursor:thin` | `cursor-agent` (tier 1 default) |
| `agent-loop-codex:thin` | Codex CLI (tier 2) |
| `agent-loop-claude:thin` | Claude Code CLI (tier 3) |

```bash
docker build -t agent-loop-cursor:thin tools/agent-loop
```

## Bind mounts and workspace scope

**Not restricted to this repo.** `AGENT_LOOP_WORKSPACE` is any host directory.

Today — **one primary mount**:

```text
-v <hostWorkspacePath>:/workspace
```

The agent CLI uses `/workspace`. Pick `hostWorkspacePath` to match the repo/worktree you want edited.

## Container local state

Subscription CLI pools (Codex, Grok) keep **runtime state off the workspace bind-mount**. Project instructions stay on the mount — discovery is cwd / workspace walk-up per vendor docs, not via `CODEX_HOME` / `GROK_HOME`.

| Pool | CLI home (ephemeral) | Auth bind-mount | Project instructions (on `/workspace`) |
| ---- | -------------------- | --------------- | -------------------------------------- |
| `codex-default` | `CODEX_HOME=/var/codex-home` | `~/.codex/auth.json` → `/var/codex-home/auth.json` | `.codex/agents/`, `.codex/hooks.json`, `.codex/config.toml` |
| `grok-default` | `GROK_HOME=/var/grok-home` | `~/.grok/auth.json` → `/var/grok-home/auth.json` | `AGENTS.md`, `CLAUDE.md`, `.claude/rules/` |
| `cursor-default` | `/root` caches | `CURSOR_API_KEY` env | `.cursor/rules/`, `.cursor/mcp.json`, `AGENTS.md` |
| `claude-default` | `~/.claude` layer | `CLAUDE_CODE_OAUTH_TOKEN` env (`.env` on host) | `.claude/settings.json`, `.claude/hooks/`, `.claude/rules/`, `.mcp.json` — `inContainerHooks: native` (image includes `jq`) |

Medley docs: [`docs/codex/local-state.md`](../../docs/codex/local-state.md), [`docs/grok-build/local-state.md`](../../docs/grok-build/local-state.md).

### Persistence tiers (no Docker named volumes for CLI homes)

| Tier | Where | Purpose |
| ---- | ----- | ------- |
| 1 — Ephemeral container | `/var/*-home`, `/root` CLI caches | Auth-adjacent sessions/sqlite; discarded on `docker run --rm` |
| 2 — Host gitignored orchestrator | `logs/runs/<runId>/`, `runtime/<runId>/` | Audit SSOT: `SUMMARY.md`, iteration logs, meta, tool-calls — survives container teardown |
| 3 — Committable / intentional | `.work/<slug>/verify/`, workspace `out/`, tracked mirrors | Operator-chosen evidence; agent implement output |

OTEL is host-side (claude-observability skill) — not wired in agent-loop containers. See `logs/README.md`, `docs/agent-loop/agent-loop-station.md`.

## Multi-workspace bind mounts (future — not implemented)

**Default today:** one workspace per invocation — preferred for isolation and simplicity.

**When one mount is enough**

- Single repo or worktree per run
- Wrapper orchestrator repo: pass the **target** checkout as `hostWorkspacePath`, not the wrapper
- Two repos sequentially: two invocations with different workspace paths

**When multi-mount may be needed (logged for future)**

| Scenario | Direction |
|----------|-----------|
| Edit repo A while **read-only** referencing repo B | Primary mount A at `/workspace`; secondary `-v B:/reference:ro` via `RunSession.additionalBindMounts` |
| Shared contract package on disk | Read-only mount of libs checkout |
| Monorepo already contains both | Single mount of monorepo root — no multi-mount needed |

Planned shape (type exists; no config surface yet):

```typescript
// RunSession.additionalBindMounts?: WorkspaceBindMount[]
// pools.local.jsonc or run.local.json — TBD
{ "hostPath": "/path/to/other-repo", "containerPath": "/reference", "readOnly": true }
```

Prompt must tell the agent which container paths are writable vs read-only. Adapter may need per-CLI flags for secondary workspaces.

**Not planned:** arbitrary many writable mounts in one iteration — too much cross-repo foot-gun; prefer two runs or one parent mount.

## Isolation between concurrent runs

| Artifact | Isolation key |
|----------|----------------|
| Agent disk state | `hostWorkspacePath` |
| Orchestrator logs | `logs/runs/<runId>/` — see `logs/README.md` |
| Docker containers | `agent-loop.run-id`, unique name |

## Environment variables

Prefer `AGENT_LOOP_*`; `RALPH_*` aliases remain. See `src/env-keys.ts`.

## Domain vocabulary

Orchestrator terms are **tool-agnostic** — vendor CLI wording stays inside adapters.

| Term | Meaning | Not |
|------|---------|-----|
| **iteration** | One agent invocation inside one run (one fresh container) | "turn" (Cursor/chat idiom), vendor "step" |
| **maxIterations** | Upper bound on iterations per run | Concurrent run count |
| **run** | One orchestrator process from start to exit | A single iteration |
| **concurrent runs** | N separate orchestrator processes | Controlled by `maxIterations` |
| **sentinel** | `<promise>CONTINUE\|NO_MORE_TASKS</promise>` in agent output | Sandcastle `completionSignal` / `COMPLETE` |
| **pool** | One CLI + image + credential row | Sandbox provider |
| **adapter** | Maps iteration context → container argv | AgentProvider class name |
| **workspace bind-mount** | Host directory mounted at `/workspace` | Worktree (git concept — caller-owned) |

When citing vendor APIs (e.g. Codex stream event `turn.completed`), label them as **vendor event names**, not medley domain terms.

## Security posture and open follow-ups

Documented mitigations (see also `review/security.md`, `review/container.md`, ADR 0013, ADR 0015):

| Concern | Mitigation |
|---------|------------|
| Bind-mount blast radius | Prefer worktree or narrow path; scope ALLOWED WRITES in prompt |
| Linked-worktree `.bare` mount | RW mount at `/.agent-loop-git/bare` — same blast radius as host `git mv`; probe + iteration parity required |
| Host filesystem escape | Docker mount limits writes to mounted tree; no arbitrary `-v` without read-only + review |
| Network egress | Thin image includes `curl`; `cursor-agent` uses Cursor cloud — accepted for implement |
| Credentials | Adapter-declared env only (`CURSOR_API_KEY`); no `gh` token in container; pool attestation |
| Permission prompts | `--trust` + `--force` headless — operator attestation required |
| MCP / local stdio | Not in thin image; `.mcp.json` readable but servers cannot spawn without host runtimes |
| Git config on bind mount | Container env `GIT_CONFIG_*` + host repair/assert; see `docs/agent-loop/git-container-boundary.md` |

**Open follow-ups** (track in issues or re-probe when upgrading `cursor-agent`):

1. Does `cursor-agent` load `.claude/settings.json` hooks without Third-party toggle? Workaround: `pool-session-bind-mounts/cursor.ts` session suppression.
2. Tier-0 probe: enumerate headless `cursor-agent` remote tools/MCP behavior; log tool calls in `*-tool-calls.jsonl`.
3. Read-only secondary mounts for reference repos — `RunSession.additionalBindMounts` shape exists; config surface TBD (see "Multi-workspace bind mounts" above).
4. Optional `docker run --network` policy for stricter egress — not implemented.

## Related docs

- Operator runbook: `README.md`
- Prompt checklist: `prompt-authoring.md`
- Run log layout: `logs/README.md`
- Sandcastle adopt/reject map: `sandcastle-comparison.md`
- Spend safety: `context/spend-safety.md`
