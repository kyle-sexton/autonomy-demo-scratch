# Sandcastle comparison — adopt vs reject vs deferred

Reference for future analysis when extending `tools/agent-loop/`. Upstream: [mattpocock/sandcastle](https://github.com/mattpocock/sandcastle) (`@ai-hero/sandcastle`).

Medley lineage: Sandcastle → `tools/agent-loop/`.

## Environment model

| Topic | Sandcastle | Agent-loop (shipped) |
|-------|------------|----------------------|
| Docker / Podman | Bind-mount host path | Bind-mount only (`hostWorkspacePath` → `/workspace`) |
| Vercel / Daytona | Sync repo in/out | **Deferred** — not pursuing unless cloud AFK required |
| Fresh context | Optional session resume/fork | **Reject** — container exit per iteration (= `/clear`) |
| Worktrees | `createWorktree()` + merge/syncOut | **External** — `prepare-workspace.sh` + caller |

## Primitive map

| Sandcastle primitive | Stance | Medley artifact |
|---------------------|--------|-----------------|
| `run({ agent, sandbox, maxIterations, completionSignal })` | Adopted | `orchestrator.ts` + `RunSession` |
| `SandboxProvider` | Adopted (Docker only) | `ContainerRuntime` in `container-runtime.ts` |
| `AgentProvider` | Adopted | `AgentCliAdapter` + `AgentPool` |
| `createSandbox()` reuse one container | Reject | Conflicts with fresh-context design |
| `createWorktree()` / commit merge | External | `prepare-workspace.sh`; merge/PR stays human |
| `idleTimeoutSeconds` | Adopted | `ITERATION_IDLE_TIMEOUT_MS` |
| `completionTimeoutSeconds` | Adopted | `ITERATION_COMPLETION_GRACE_MS` |
| `onAgentStreamEvent` | Adopted (pattern) | stream-json + `meta.json` + tool-calls sidecar |
| Session resume/fork | Reject | Deliberately omitted |
| `Output.object` / Zod tag | Deferred | Prompt + filesystem completion sufficient today |
| `hooks` (npm install pre-agent) | Deferred | Use prompt or host prep |

## Terminology (use medley names in code/docs)

| Medley | Sandcastle-ish |
|--------|----------------|
| iteration | turn / step |
| sentinel (`CONTINUE` / `NO_MORE_TASKS`) | `completionSignal` / `COMPLETE` |
| pool | agent + sandbox row |
| adapter | `AgentProvider` |
| workspace bind-mount | sandbox mount path |

Full vocabulary: `ARCHITECTURE.md` "Domain vocabulary".

## Shipped vs still open (2026-06)

| Concern | Status |
|---------|--------|
| Runtime timeouts + fs-before-abort | Done |
| Observability (stream-json, meta, container snapshot) | Done |
| Multi-pool (Cursor, Claude, Codex, Grok adapters) | Done — enable per pool locally |
| External git helper | Done — `prepare-workspace.sh` |
| Spend-safety attestation | Done — `operator/spend-safety-attestation-*.json` |
| Podman runtime | Deferred |
| Cloud sandbox | Deferred |
| In-orchestrator PLAN parsing | Deferred |
| Session resume | Rejected |
| Sandcastle syncOut / git am merge | Deferred — separate product surface |

## Re-analysis triggers

Re-read Sandcastle when considering: cloud AFK, merge automation, structured `Output.object` handoffs, Podman parity, or adopting `@ai-hero/sandcastle` instead of roll-own orchestrator.
