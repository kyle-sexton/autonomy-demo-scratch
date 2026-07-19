# agent-loop

Headless **implement-only** loop: fresh Cursor CLI (`cursor-agent`) in a Linux container each **iteration**, until caller-defined done or `maxIterations`.

Architecture: `ARCHITECTURE.md`. Prompt authoring: `prompt-authoring.md`. AFK CLI authority: `headless-cli-authority.md`.

**When to use:** `docs/agent-loop/loop-primitives.md` (decision tree). Boundary detail: `docs/agent-loop/agent-loop.md` "When to use agent-loop vs alternatives".

## What this tool is — and is not

| In scope (this tool) | Out of scope (callers / other tooling) |
|----------------------|----------------------------------------|
| Fresh-context implement iterations in Docker | Explore, research, architect, or preplan |
| Spawn → run agent → parse sentinel → respawn | Sequencing subslices in dependency order |
| Caller-supplied `prompt` + bind-mounted workspace | Reading `.work/` PLAN or issue graphs (prompt points; tool does not) |
| Generic completion (e.g. file count in `out/`) | GitHub issue orchestration, `/handoff` generation |
| One pool + profile per **invocation** (`run.local.json`, `RALPH_MODEL`) | Picking which subslice gets which model |
| `maxIterations` — max iterations per run | Concurrent runs (start N processes; cap 1–5 yourself) |

**Design must:** the tool stays dumb. Planning, scheduling, and “where is the plan?” are **external**; the prompt tells the agent which files to read and what done means. Something else picks order (you, a script, issues) and invokes this tool per chunk with workspace + prompt + profile + cap.

**Iterations vs concurrent runs:** `maxIterations` (CLI arg 1, `RALPH_MAX_ITERATIONS`, or `run.local.json`) caps **iterations inside one run** — each iteration is a fresh container. Running three slices in parallel = three orchestrator **processes**; that is separate from `maxIterations`.

**Model profiles:** use tool-agnostic `role` or `effort` in `run.local.json`; the adapter maps to Cursor model slugs. Explicit `model` or `RALPH_MODEL` bypasses the table. See `prompt-authoring.md`.

## Is this a “real” Ralph loop?

**Yes — same pattern, different harness.** What keeps the loop alive is **this orchestrator** (`orchestrator.ts`): a `for` loop over iterations, each spawning a **fresh** container (kill-on-exit), then `decideCompletion()` from filesystem progress + `<promise>CONTINUE|NO_MORE_TASKS</promise>`.

| Mechanism | CC Ralph plugin / `claude -p` outer loop | This tool |
|-----------|------------------------------------------|-----------|
| Loop driver | In-session plugin or bash `while` | Node orchestrator + Docker |
| Fresh context | `claude -p --no-session-persistence` | New container per iteration |
| Done signal | `<promise>DONE</promise>` per spec | `<promise>CONTINUE\|NO_MORE_TASKS</promise>` + file count in `out/` |
| Ground truth | Grep specs for DONE tokens | File count in bind-mounted `out/` (authoritative) |

Lineage: [Sandcastle](https://github.com/mattpocock/sandcastle) → `tools/agent-loop/`. Comparison map: `sandcastle-comparison.md`.

## Prerequisites

- Docker Desktop (or Docker Engine on Linux)
- Node ≥24 (`fnm use` from repo root)
- Cursor User API Key (`crsr_…`) from **Settings → Integrations → User API Keys**
- AFK slices: `bash tools/model-routing/route-for-surface.sh` per `docs/model-routing/README.md` "Pit of success" (writes `run.local.json`)

## Cursor IDE terminal (host launch only)

[Cursor Agent terminal](https://cursor.com/docs/agent/tools/terminal) documents the **IDE Agent Shell tool** — sandbox, Run Mode, allowlists, `sandbox.json`. That stack applies when **you or a Cursor Agent session** start the orchestrator on the host (`npm start`, `node build/orchestrator.js`, shell tests). It does **not** govern loop iterations: each iteration runs `cursor-agent` in a **fresh Docker container** with its own boundary (bind-mount, spend attestation, adapter flags).

| Layer | Safety boundary |
|-------|-----------------|
| Host launch (IDE terminal) | Cursor sandbox / Run Mode / allowlist — `docs/cursor/hooks.md` "Agent terminal (Windows)" |
| In-container (`cursor-agent`) | Docker + `CURSOR_API_KEY` + headless flags; not IDE `sandbox.json` |
| AFK policy SSOT | This README + `headless-cli-authority.md` |

**Windows:** a native `D:\…` workspace plus a "(with sandbox)" Run Mode can make IDE shell commands return "no exit status" before spawn — use **Auto-review** (no sandbox) or Remote-WSL. `docker run` inside Agent Loop is unaffected; only the **host** command that starts the orchestrator hits this trap.

**Linux `docker run --user`:** resolve via `AGENT_LOOP_UID` / `AGENT_LOOP_GID` or workspace owner stat (`src/container-user.ts`) — not Cursor's `CURSOR_ORIG_UID` / `CURSOR_ORIG_GID`. Set `AGENT_LOOP_*` explicitly when launching from Cursor's Linux sandbox where `id -u` is remapped.

## First-time setup

Each contributor on each machine:

### 1. Spend safety

Before any credentialed run, confirm `cursor-agent` + `CURSOR_API_KEY` draws from your **subscription pool** (not a separate metered API). Set on-demand to **Disabled** — the UI rejects a literal `$0`; "Disabled" hard-stops overflow charges.

1. [cursor.com/dashboard/spending](https://cursor.com/dashboard/spending) → Monthly Limit → **Disabled** (not `$0`)
2. Canary: `cursor-agent -p "Return HELLO"` (or wait for container smoke below)
3. [cursor.com/dashboard/usage](https://cursor.com/dashboard/usage) → On-Demand stays **$0.00**

Record attestation (no secrets) after dashboard canary — copy `operator/spend-safety-attestation.example.json`:

```json
{"capHardStops":true,"subscriptionBilled":true,"confirmedAt":"<ISO-8601>","pool":"cursor-default"}
```

Save as `tools/agent-loop/operator/spend-safety-attestation-cursor.json` (gitignored). See `operator/README.md`.

### 2. Credentials

**Option A — `.env` file (dotenv convention, easiest for `npm start`):**

```bash
cd tools/agent-loop
cp .env.example .env
# edit .env — set CURSOR_API_KEY=
```

**Option B — OS environment (cross-tool; also used by bare `cursor-agent` on the host):**

```powershell
# Windows — new terminal after setx
setx CURSOR_API_KEY "crsr_..."
```

```bash
# macOS / Linux — add to ~/.bashrc or ~/.zshrc
export CURSOR_API_KEY="crsr_..."
```

Precedence: **OS env wins**; `.env` only fills vars that are unset or empty.

Never commit `.env`, operator attestation files, or key values.

### 3. Run config (profile, max iterations, output)

Copy the example and edit per machine:

```bash
cp run.example.json run.local.json
cp pools.example.jsonc pools.local.jsonc
```

Select pool via `pools.local.jsonc` `defaultPoolId`, `run.local.json` `"poolId"`, or `AGENT_LOOP_POOL` / `RALPH_POOL`.

`run.example.json` sets `"outputFormat": "text"` for toy/smoke (smaller logs). When omitted from `run.local.json`, the orchestrator defaults to **`stream-json`** for AFK runs (structured `meta.json`, optional `*-tools.jsonl`, live tee — see Visibility).

AFK runs should set explicit **`model`** via `docs/model-routing/README.md` "Pit of success" (`route-for-surface.sh` → `run.local.json`). Role defaults are escape hatch only:

| `role` | Use case |
|--------|----------|
| `mechanical` | Simple edits → Composer 2.5 Fast (`composer-2.5-fast`) |
| `implement` | Default when no explicit `model` → `composer-2.5-fast` |
| `deep` | Hard reasoning → Opus 4.8 thinking xhigh |

Or use `effort` (`low` … `extra-high`) + optional `"thinking": true` instead of `role`.

**Agent failure policy:** if the headless agent CLI exits non-zero (rate limit, auth, tool error), the orchestrator **stops immediately** (exit **7**) — it does **not** auto-continue or auto-switch models. Read the iteration log, discuss prompt/model changes with the operator, then re-invoke explicitly. **Lower-cost retry default (per pool):** `role: "mechanical"` in `run.local.json` or an explicit `AGENT_LOOP_MODEL` — the orchestrator prints the mapped slug for the active tool (e.g. Cursor → `composer-2.5-fast`; see model profile table above).

**Max iterations:** `"maxIterations": 6` in `run.local.json`, or CLI arg 1, or `RALPH_MAX_ITERATIONS`. Default **6** is a safety cap for toy runs and short slices — raise it (e.g. 12–30) for long autonomous implement slices once the prompt’s completion checks are solid; the cap limits runaway token burn, not concurrent runs.

List raw model slugs:

```bash
docker run --rm -e CURSOR_API_KEY agent-loop-cursor:thin cursor-agent --list-models
```

**Precedence:** explicit `model` / `RALPH_MODEL` → `role` / `effort` mapping → default implement profile.

### 4. Build

```bash
cd tools/agent-loop
npm install
npm run build
docker build -t agent-loop-cursor:thin .

# Cloud-parity pool (Ubuntu + tools/cloud-setup/setup.sh) — build from repo root:
# docker build -f tools/agent-loop/docker/cursor/Dockerfile.cloud-parity -t agent-loop-cursor:cloud-parity .
# Then set pools.local.jsonc defaultPoolId to "cursor-cloud-parity" or override containerImage.
# Additional CLI pools (enable in pools.local.jsonc):
# docker build -t agent-loop-claude:thin -f docker/claude/Dockerfile .
# docker build -t agent-loop-codex:thin -f docker/codex/Dockerfile .
```

**Pool tiers:** tier 1 `cursor-default` (default) · tier 2 `codex-default` · tier 3 `claude-default` (optional — tier-0 + attestation; billing SSOT: `docs/claude-code/rate-limit-reference.md` "Agent SDK and claude -p subscription billing") · tier 4 `grok-default` (optional — host `~/.grok/auth.json` + Grok CLI). CLI authority: `headless-cli-authority.md`.

**Migration from `*-phase1` pool ids:** update gitignored `pools.local.jsonc` keys and attestation `"pool"` field to match new ids (`cursor-default`, etc.). Old ids were internal roadmap labels, not slice PLAN phases.

### Headless Cursor pool — in-container hooks suppressed

Cursor pools (`cursor-default`, `cursor-cloud-parity`) set `inContainerHooks: suppressed` on the pool row. Before each run the orchestrator generates gitignored files under `runtime/` and bind-mounts them **inside the container only**:

- stripped `.claude/settings.json` (no `hooks` key)
- empty `.cursor/hooks.json` (`{"version":1,"hooks":{}}`)

Host workspace and desktop Third-party import are unchanged — no committed `.cursor/hooks.json` on the host. Aligns with [Cursor cloud hook support](https://cursor.com/docs/hooks#cloud-agent-support) and medley `docs/cursor/hooks.md` "Hooks" (cloud D1). Authoritative gates: **host verify** + Lefthook + CI.

**Tier-0 gate** (spend-gated; run before slice retest on cursor-default):

```bash
bash scripts/pool-gates/cursor-write.sh
```

Implementation: `src/pool-session-bind-mounts/cursor.ts` via `resolvePoolSessionBindMounts` (see `ARCHITECTURE.md`).

### Headless Claude pool — native in-container hooks

`claude-default` sets `inContainerHooks: native` on the pool row. The official `claude` CLI runs medley `.claude/hooks/*` inside the container (thin image includes `jq`). **Unlike Cursor**, Claude is not hook-suppressed — Cursor suppression exists because `cursor-agent` headless hits hook transport failures, not because medley hooks are unwanted for Claude.

**Tier-0 gate** (spend-gated; compliance sign-off before credentialed run):

```bash
bash scripts/pool-gates/claude-write.sh
```

Auth: `CLAUDE_CODE_OAUTH_TOKEN` in gitignored `tools/agent-loop/.env` from `claude setup-token`. Never `ANTHROPIC_API_KEY`.

Implementation: [`src/adapters/claude.ts`](src/adapters/claude.ts), [`src/claude-headless-config.ts`](src/claude-headless-config.ts).

## Container vs host environment

Inside Docker, the bind-mounted workspace appears at **`/workspace`** (`CONTAINER_WORKSPACE_MOUNT`). The orchestrator sets `CLAUDE_PROJECT_DIR=/workspace` per iteration via `additionalContainerEnv` — **not** via image `ENV`.

On your **host** (native Claude Code, Git Bash, Windows Terminal):

- **Never** `export` or `setx CLAUDE_PROJECT_DIR /workspace` — that path exists only in containers.
- **Never** `export GIT_WORK_TREE=/workspace` on the host.
- In-container git can persist `core.worktree=/workspace` into bare-hub `.bare/config` — orchestrator repairs on start/end; verify with `bash tools/agent-loop/scripts/check-host-container-env-boundary.sh`.
- On **Windows**, Linux container git on the bind mount can flip `core.filemode` to `true` in shared `.git/config`, flooding `git status` with exec-bit phantom diffs (`100755`→`100644`, zero line changes). Every container run injects `GIT_CONFIG` `core.fileMode=false`; orchestrator resets host `core.filemode=false` on start/end. One-time host pin: `bash tools/bootstrap.sh` (or `git config --local core.filemode false`). Same self-heal runs in `.claude/hooks/worktree-setup.sh` on Claude Code SessionStart.
- After an agent-loop run, check `.claude/settings.local.json` for persisted `/workspace` paths and remove them.
- Full risk register + cross-platform checklist: `docs/agent-loop/git-container-boundary.md`.
- **Orchestrator preflight** (before Docker spend): repairs host git config leaks, then **exit 9** if still dirty. **Manual/CI audit**: `bash tools/agent-loop/scripts/check-host-container-env-boundary.sh`.

Container paths in **prompt prose** (`WORKSPACE: bind-mounted at /workspace`) are fine. Do not write container paths into tracked config or `settings.local.json` — see `prompt-authoring.md`.

## Run

```bash
cd tools/agent-loop
npm start    # toy example: workspace/ + examples/toy-backlog.prompt.md
```

Real work — point at any worktree or slice directory:

```bash
# Optional: create worktree path (stdout is path-only with --print-path)
export AGENT_LOOP_WORKSPACE="$(bash prepare-workspace.sh create --repo /path/to/repo --branch feat/slice --path /path/to/worktree --print-path)"

node build/orchestrator.js 8 examples/medley-implement.prompt.md 1 "$AGENT_LOOP_WORKSPACE"

# Optional: append git summary to orchestrator.log after the loop
bash prepare-workspace.sh summary --workspace "$AGENT_LOOP_WORKSPACE" --run-log logs/runs/<runId>/orchestrator.log
```

Toy / smoke:

```bash
node build/orchestrator.js 8 .work/<slug>/research/implement.prompt.md 1 /abs/path/to/worktree
```

CLI: `node build/orchestrator.js [maxIterations] [prompt-file] [target-count] [workspace-path]`

| Arg / env | Meaning |
|-----------|---------|
| `maxIterations` / `RALPH_MAX_ITERATIONS` | Max **iterations** in this run |
| `prompt-file` / `RALPH_PROMPT` | Path to `.prompt.md` (content passed verbatim) |
| `target-count` / `RALPH_TARGET` | Completion artifact count in `outSubdir/` |
| `workspace-path` / `RALPH_WORKSPACE` | Bind-mount root (absolute or cwd-relative) |
| `RALPH_OUT_SUBDIR` | Completion dir under workspace (default `out`) |
| `AGENT_LOOP_RUN_ID` / `RALPH_RUN_ID` | Optional **label suffix** for the run folder (timestamp is always prefixed) |
| `RALPH_LOG_DIR` | Override log base (default `tools/agent-loop/logs/runs/<runId>/`) |
| `AGENT_LOOP_UID` / `AGENT_LOOP_GID` | Linux: `docker run --user` for bind-mount ownership (auto from workspace stat when unset) |

Prompt files use **`.prompt.md`** — Markdown for authoring; the orchestrator reads raw text and does not interpret frontmatter.

| `RALPH_*` / `AGENT_LOOP_*` | See `ARCHITECTURE.md` and `src/env-keys.ts` |

Prefer `AGENT_LOOP_*` env names; `RALPH_*` aliases still work.

## Isolation (worktrees and concurrent runs)

| Concern | Mechanism |
|---------|-----------|
| **Agent state on disk** | Bind-mount **your** workspace path (worktree, `.work/<slug>/`, etc.) — each invocation is independent |
| **Same workspace, two loops** | Use distinct `RALPH_RUN_ID` values; container names include workspace slug + run tail + iteration |
| **Orchestrator logs** | `logs/runs/<runId>/orchestrator.log` and `iteration-NN-<cli>-*` files — see `logs/README.md` |
| **Docker filters** | `docker ps --filter label=agent-loop.run-id=<id>` |

The tool does not manage worktree creation or concurrency caps — start N processes yourself; keep N low (e.g. 1–5) for Cursor rate limits.

## Docker identity

Each iteration gets a **named** container and labels:

| Field | Example |
|-------|---------|
| Name | `agent-loop-cursor-my-slice-004442781Z-i1` |
| Label `agent-loop.cli` | `cursor` |
| Label `agent-loop.run-id` | `{compactUtcTimestamp}-{label}` |
| Label `agent-loop.workspace-slug` | basename of bind-mounted dir |
| Label `agent-loop.iteration` | `1`, `2`, … |

```bash
docker ps --filter label=agent-loop.cli=cursor
docker ps --filter label=agent-loop.run-id=2026-06-10T004442781Z
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completion target met **and** host verify passed (when `AGENT_LOOP_HOST_VERIFY_SCRIPT` set) |
| 2 | Watchdog kill (idle timeout) |
| 3 | Stuck — false completion or no progress |
| 4 | Iteration cap reached |
| 5 | Missing credentials |
| 6 | Prompt too large |
| 7 | Agent CLI failed — **stop for operator review** (no auto-retry) |
| 8 | Host verify script failed after agent claimed done |
| 9 | Host git config still carries container leaks after repair |

## Visibility

See `logs/README.md` for the full layout. Summary:

| Path | Contents |
|------|----------|
| `logs/runs/<runId>/SUMMARY.md` | **Start here** — always written (success or abort); outcome, tokens, git, probe, hook failures, verify, digest |
| `logs/runs/<runId>/container-probe.json` | Pre-loop dependency + hook dry-run inside the pool image |
| `logs/runs/<runId>/iteration-NN-<cli>-hook-report.json` | Classified hook blocks per iteration (`launcher_transport`, `policy_block`, `missing_dependency`) |
| `logs/runs/<runId>/orchestrator.log` | Run banner, iteration summaries, decisions |
| `logs/runs/<runId>/iteration-NN-<cli>-agent-output.log` | Agent stdout for iteration N (live-tee during run) |
| `logs/runs/<runId>/iteration-NN-<cli>-meta.json` | elapsedMs, exit, sentinel, killReason, watchdog flags, usage when present |
| `logs/runs/<runId>/iteration-NN-<cli>-tool-calls.jsonl` | `tool_call` NDJSON lines when `outputFormat` is `stream-json` |
| stdout | Same structured blocks as orchestrator.log |

**Live output:** `tail -f logs/runs/<runId>/iteration-01-cursor-agent-output.log` while a run is in progress. With `stream-json`, orchestrator.log links to the agent-output file instead of duplicating NDJSON.

## Tests

```bash
npm test    # vitest — pure logic + docker argv builders
npm run lint
```

| Layer | Tested? | How |
|-------|---------|-----|
| Sentinel parse, completion truth-table, gate, env load | yes | unit tests |
| Idle timeout, completion grace, fs-before-abort, prompt byte guard | yes | `iteration-timeout`, `tracked-spawn`, `run-loop`, `preflight/*.test.ts` tests |
| Run config / model profiles / maxIterations | yes | `run-config.test.ts`, `model-profiles/*.test.ts` |
| Docker container name + `docker run` argv | yes | `docker-run.test.ts` |
| Console / run-log formatting | yes | `run-console.test.ts` |
| Cursor adapter shape | yes | `adapters.test.ts` |
| **Orchestrator loop** (`spawn` → real Docker) | no | manual e2e (`npm start`) when spend-safety attestation present |

The loop is the humble-object shell; a fake-adapter integration test without Docker may follow later.

## Design gaps (implement loop only)

| Gap | Today | Target |
|-----|-------|--------|
| **Runtime reliability** | Idle timeout, completion grace, fs-before-abort, prompt byte guard | Done |
| **Observability** | stream-json, hook classification, container probe, SUMMARY on all exits | Done |
| **Container runtime seam** | `ContainerRuntime` + Docker impl | Done |
| **Multi-tool** | Cursor + Claude + Codex adapters via `pools.local.jsonc` | Done — enable per pool in local config |
| **Model / CLI flags** | `role`, `effort`, `thinking`, or explicit `model` | Per-CLI tables in `model-profiles/<cli>.ts` |
| **Per-tool auth** | Adapter-declared env + optional credential bind mounts | Done |
| **Completion signal** | Caller sets target file count + prompt sentinel | Richer caller-defined checks stay in **prompt**, not orchestrator |
| **Concurrent loops** | Manual N invocations; unique container names | Optional external supervisor with max 1–5 |
| **Live output** | Live tee to iter log (`tail -f`) | Done |
| **Spend-safety attestation** | Per-pool marker files (Cursor, Claude, Codex) | Done |
| **Codex tier-2 Tier-0 gate** | `scripts/pool-gates/codex-write.sh` | Done (spend-gated) |

**Explicitly not planned in this tool:** PLAN parsing, subslice scheduling, issue dependency resolution, or autonomous planning modes (`--mode plan` is never used by the adapter).

## Scope notes

- **Local Docker only** — cloud injects credentials via platform secrets, not `.env`.
- **Subscription-billed, hard-capped** — spend-safety attestation before credentialed runs; see setup above.
- `pools.local.jsonc` selects built-in pool rows (`cursor-default`, `codex-default`, `claude-default`) — still no planning or sequencing inside the loop.

## Future considerations (not implemented)

See **`ARCHITECTURE.md`** — multi-CLI Docker images, auth per pool, **`Multi-workspace bind mounts (future)`** (one mount today; optional read-only second repo later via `additionalBindMounts`).
