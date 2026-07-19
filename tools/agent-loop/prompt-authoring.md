# Agent loop prompt authoring

Use this checklist when preparing a slice for `tools/agent-loop`. The orchestrator is **convention-neutral**: it bind-mounts a directory, runs your prompt, and checks generic completion signals. **All** medley context — PLAN paths, issue numbers, dependency order, what to edit — lives in the prompt, not the tool.

Generate or save a prompt file **only after the user opts in** (agent may suggest agent loop once; do not auto-create artifacts).

## Prerequisites (before invoking the loop)

- [ ] **Model routing (AFK):** `bash tools/model-routing/route-for-surface.sh --slice .work/<slug> --surface agent-loop-cursor --phase <N>` — writes `run.local.json` with explicit `model`. See `docs/model-routing/README.md` "When routing is required".
- [ ] Explore / research / architect stages are **done** for this chunk — no planning inside the loop.
- [ ] PLAN phase(s) for this chunk are scoped to ≤400k context and tagged `[TODO]` with clear acceptance.
- [ ] Bind-mount target exists (worktree or `.work/<slug>/` subdir) with repo access as needed.
- [ ] Spend-safety attestation present (`operator/spend-safety-attestation-cursor.json` — see `operator/README.md`).
- [ ] Completion ground truth is **machine-checkable** (file markers, test command output path, etc.) — not vibes.

## Prompt must include

1. **Scope fence** — what directories/files may be modified; explicit "do not plan or expand scope."
2. **Single-chunk goal** — one PLAN phase or one issue's implement scope per invocation.
3. **Progress read** — how the agent discovers what's already done (list `out/`, read PLAN tags, etc.).
4. **Work steps** — ordered actions for *this iteration only* (not the whole EPIC).
5. **State writes** — what to update on disk when a unit completes (PLAN tag, README Status — if medley slice).
6. **Sentinel contract** — final line exactly `<promise>CONTINUE</promise>` or `<promise>NO_MORE_TASKS</promise>`. Do not repeat those literal tags elsewhere in the prompt body (stream-json logs echo the user message; extra tags cause false completion parses).
7. **Honesty rule** — `NO_MORE_TASKS` only when ground-truth completion criteria are satisfied.
8. **Missing capability** — if a step needs host-only or absent-container tooling (`docs/adr/0013-agent-loop-thin-container-images.md`), stop: write `out/phase-N.blocked` or `out/needs-elevation.md` (missing tool, why, suggested elevation); emit `NO_MORE_TASKS` only after the blocker exists. Do not mount host PATH or invent credentials.
9. **Progress-claim audit** — before reporting progress, audit each claim against a tool result from this iteration; if a check fails, say so with the output. Complements — does not replace — the final-sentinel Honesty rule (item 7): item 7 gates the completion sentinel, this gates every interim progress report ([prompting-fable-5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5)).
10. **End-of-iteration intent check** — before ending an iteration, check the last paragraph: if it states a plan or intent without a tool call having done the work, do the work now ([prompting-fable-5]). Stated intent is not progress.
11. **Divergence handling (conservative-continue)** — no human is present to escalate to: when reality diverges from the plan but the phase's core assumption holds, pick the CONSERVATIVE option (truest to plan intent, smallest blast radius), log it in `DEVIATIONS.md` at deviation time, and continue. When a fundamental assumption is wrong, stop — write `out/phase-N.blocked` per item 8; never improvise a new design mid-loop. Mirrors `/implement` Step 3 "Non-interactive fork (autonomous runs only)".

## Orchestrator parameters (operator / wrapper sets these)

| Parameter | Meaning | Example |
|-----------|---------|---------|
| `maxIterations` | Max **iterations** in one run (fresh container each iteration) | `6` in `run.local.json` or CLI arg |
| `target` | Filesystem completion count (e.g. marker files in `out/`) | `2` for two phase markers |
| `workspace-path` | Bind-mounted directory | `.work/<slug>/` |
| `role` / `effort` | Tool-agnostic model profile → adapter maps to vendor slug | Prefer explicit `model` from `route-for-surface.sh` |

**Not the same as concurrent loops:** running three slices at once = three orchestrator processes; cap each with `maxIterations` separately. Limit parallel runs to 1–5 operationally.

## Model profile guidance (per pool)

Official CLI flags: `tools/agent-loop/headless-cli-authority.md`. Slug tables: `tools/agent-loop/src/model-profiles/<cli>.ts` — AFK runs should set explicit `model` via `docs/model-routing/README.md` "Pit of success" instead of relying on role defaults.

### Tier 1 — `cursor-default`

| Profile | When | Slug |
| ------- | ---- | ---- |
| `role: "mechanical"` | Simple edits | `composer-2.5-fast` |
| `role: "implement"` | Escape hatch when no manifest | `composer-2.5-fast` |
| `role: "deep"` | Hard reasoning | `claude-opus-4-8-thinking-xhigh` |

### Tier 2 — `codex-default`

| Profile | When | Slug |
| ------- | ---- | ---- |
| `role: "mechanical"` | Simple edits | `gpt-5.3-codex-spark` |
| `role: "implement"` | Default autonomous implement | per `model-profiles/codex.ts` |

### Tier 3 — `claude-default`

Billing posture: `docs/claude-code/rate-limit-reference.md` "Agent SDK and claude -p subscription billing". Enable pool after tier-0 write gate passes, operator attestation, and compliance sign-off ([`context/compliance-posture.md`](context/compliance-posture.md)). Auth: `CLAUDE_CODE_OAUTH_TOKEN` in gitignored `tools/agent-loop/.env`.

| Profile | When | Slug |
| ------- | ---- | ---- |
| `role: "mechanical"` | Simple edits | `claude-haiku-4-5` |
| `role: "implement"` | Default | per `model-profiles/claude.ts` |

Explicit `model` in `run.local.json` or `RALPH_MODEL` bypasses the table (escape hatch).

## When an iteration fails (operator, not the loop)

If the headless agent CLI exits non-zero, the orchestrator **stops** (exit **7**) — no next iteration, no automatic model switch. Before re-running:

1. Read `logs/runs/<runId>/iteration-NN-*-agent-output.log` and `*-meta.json`.
2. Decide with the operator: adjust prompt, narrow scope, or change model.
3. **Lower-cost profile:** `role: "mechanical"` or explicit `AGENT_LOOP_MODEL` — slug is per active pool (see model profile table above; failure stderr prints the mapping).
4. Re-invoke only after explicit go-ahead.

## Suggested slice artifact (optional, user-confirmed)

If the user wants a tracked prompt file: `.work/<slug>/research/implement.prompt.md` — passed to the orchestrator as the prompt path. Do not create unless asked.

## Template (copy and fill)

```text
You are implementing one bounded chunk autonomously. Do NOT plan, research, or expand scope.

WORKSPACE: bind-mounted at /workspace (host: <path>).

READ FIRST:
- PLAN.md — execute ONLY the next [TODO] phase.
- out/ — list existing completion markers.

GOAL (ground truth):
- WHY: <one line — why this work exists, who it's for, what the output enables>
- <list concrete files or artifacts that must exist when done>

THIS ITERATION:
1. <step>
2. <step>
3. Update PLAN.md phase tag [TODO]→[DONE] and README.md ## Status when a phase completes (if applicable).

ALLOWED WRITES: <paths — include DEVIATIONS.md and out/ so the DIVERGENCE clause can log without breaching the fence>

PROGRESS REPORTING: before reporting progress, audit each claim against a tool result from this iteration; if a check fails, say so with the output.

DIVERGENCE: if reality diverges from the plan but the phase's core assumption holds, pick the conservative option, log it in DEVIATIONS.md, and continue. If a fundamental assumption is wrong, write out/phase-N.blocked and stop — do not redesign mid-loop.

BEFORE ENDING THE ITERATION: check your last paragraph — if it states a plan or intent without a tool call having done the work, do the work now, then emit the sentinel.

CONFIG BOUNDARY (container sessions): Never run `git config` in the container — host owns repo-local git config. Never write `CLAUDE_PROJECT_DIR`, `GIT_WORK_TREE`, or `/workspace` paths into `.claude/settings.local.json`, `.claude/settings.json`, or any tracked config. Container mount paths belong in prompt prose only — host Claude Code and git hooks resolve real host paths. SSOT: `docs/agent-loop/git-container-boundary.md`.

When more work remains after this iteration: <promise>CONTINUE</promise>
When GOAL is fully satisfied on disk: <promise>NO_MORE_TASKS</promise>

VERIFICATION (required before NO_MORE_TASKS):
- Run: <exact test command>
- Pass: exit code 0 AND <ground-truth artifacts>
- Fail: fix and emit CONTINUE
```

Medley-wide convention: `docs/agent-loop/agent-loop.md`. Loop primitive selection: `docs/agent-loop/loop-primitives.md`.

## Verification ladder

Looped work must **close the verification loop** — pass/fail gate, not agent self-report. Full runbook: `docs/agent-loop/verification-ladder.md` "Autonomous orchestration bundle".

| Rung | Use in agent-loop prompts |
|------|---------------------------|
| 2 (minimum) | Require a named command before `NO_MORE_TASKS` (e.g. `dotnet test`, `bash tools/run-shell-tests.sh`) |
| 2 + markers | Require files in `out/` **and** test exit 0 |
| 5 | Fresh-context verifier per phase — prompt cites loop-primitives Orchestrator contract |

**Orchestration:** prompt MUST instruct autonomous orchestration mode — cite `docs/agent-loop/loop-primitives.md` "Orchestrator contract" (dispatch per PLAN phase; main session does not volume-edit). Invoke `/orchestration-brief worker` for spawn preamble when fan-out.

Agent-loop has no `/goal` — encode rung 2 explicitly in § Prompt must include and template below.

### Acceptance block (add to GOAL section)

```text
VERIFICATION (required before NO_MORE_TASKS):
- Run: <exact command>
- Pass: exit code 0 AND <artifact exists on disk>
- Fail: fix and emit CONTINUE
```

Example:

```text
VERIFICATION (required before NO_MORE_TASKS):
- Run: dotnet test --project tests/MonolithApi.Tests
- Pass: exit code 0 AND PLAN.md Phase 2 tag is [DONE]
- Fail: fix and emit CONTINUE
```

For Claude Code sessions (not Docker agent-loop), prefer **interactive `/goal`** — `session-loop-runbook.md` Pilot A; orchestration: `loop-primitives.md` "Orchestration mode".

## Per-pool capabilities (profiles + probe)

Declarative profiles: `tools/agent-loop/capabilities/<id>.json`. Each pool row sets `capabilityProfileId` (`thin` default; `cursor-cloud-parity` → `cloud-parity`). Ground truth at run time: `container-probe.json` → `capabilitiesResolved` + `gitBridge`.

Prompts must not promise tooling absent from the profile (`docs/adr/0013-agent-loop-thin-container-images.md`). **Hook enforcement in thin pools:** host verify + Lefthook + CI — not in-container medley hooks unless the pool row says `inContainerHooks: native`.

| Capability | `thin` profile | `cloud-parity` profile |
| --- | --- | --- |
| `gitBridge` | `auto` (linked worktree bridge per ADR-0015) | `auto` |
| `verifyPlane` | `host` | `container` |
| `node` / `npm` | No | Yes |
| `dotnet` | No | Yes |
| `inContainerHooks` (cursor pools) | `suppressed` | `suppressed` |

**Git in container:** `git mv` within `ALLOWED WRITES` when probe reports `gitBridge.mode: read-write`. Never `commit`/`push` in-container. Tier-0: `bash tools/agent-loop/scripts/verify-worktree-git-bridge.sh`.

When verification needs medley toolchain on `thin`, use host verify after the loop or select `cursor-cloud-parity` pool — document in the prompt acceptance block.
