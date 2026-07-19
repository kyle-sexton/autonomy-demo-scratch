# Worktree tools

Git-native worktree lifecycle for this repo — create, setup, boundary enforcement. Mechanism SSOT for all agent surfaces (Claude hooks, Cursor `worktrees.json`, agent-loop).

## Contract surfaces

| Entry | Role |
| --- | --- |
| `create-worktree.sh` | `git worktree add` + branch derivation + `.worktreeinclude` copy |
| `setup-worktree.sh` | Post-create / session runtime provisioning (pipelines) |
| `setup-cursor-worktree.sh` | Cursor adapter (`ROOT_WORKTREE_PATH` → `setup-worktree.sh --pipeline cursor`) |
| `enforce-boundary.sh` | Cross-worktree Write/Edit guard |
| `status.sh` | Tier-0 worktree inventory facts (`/worktree status`, `audit`) |
| `worktree.sh` | Operator dispatcher (`setup`, `create`, `status`, `list-orphans`) |

## Adapter surfaces

Thin adapters delegate to entry scripts only — **must not** `source` `tools/worktree/lib/`:

| Adapter | Entry |
| --- | --- |
| `.claude/hooks/worktree-create.sh` | `create-worktree.sh` |
| `.claude/hooks/worktree-setup.sh` | `setup-worktree.sh --pipeline claude-session-start` |
| `.claude/hooks/worktree-boundary.sh` | `enforce-boundary.sh --emit-diagnostic` |
| `.cursor/worktrees.json` | `setup-cursor-worktree.sh` |
| `tools/agent-loop/prepare-workspace.sh` | `create-worktree.sh` + `agent-loop-post-create` pipeline |

Hook adapters own stdin/stdout protocol, `hook::ctx_*`, and observability only.

## Setup pipeline

Pipelines are inline functions in `setup-worktree.sh` (`--pipeline <name>`):

| Pipeline | Steps | Fail policy |
| --- | --- | --- |
| `cursor` | copy-includes → bootstrap → dotnet(always) | soft |
| `claude-session-start` | detect session → main phase (skip bare-hub) → worktree phase when linked | soft |
| `claude-session-start-main` | bootstrap(main, skip bare-hub) → fix-upstream → heal-filemode | soft |
| `claude-session-start-worktree` | heal-filemode → fetch(bg)+marker → dotnet(if-stale) → bootstrap(worktree) → orphan-advisory(ctx) | soft |
| `agent-loop-post-create` | copy-includes → bootstrap → dotnet(if-stale) → heal-filemode | soft |

Policy (when/why, branch naming): `.claude/rules/worktree/`. Manual gitignored recipes: `docs/worktree/worktree-reference.md`.

## Output contracts

| Script | stdout | stderr | Exit codes |
| --- | --- | --- | --- |
| `create-worktree.sh` | Single normalized worktree path line | git progress, reuse notices | `0` success/reuse; `1` git/layout failure; `2` usage |
| `setup-worktree.sh` | Session-start ctx lines only (pipelines `claude-session-start-*`) | `[worktree-setup]` operational logs | `0` success; `2` usage/unknown pipeline |
| `enforce-boundary.sh` | (none) | Block diagnostic when `--emit-diagnostic` | `0` allow/fail-open; `2` block |
| `worktree.sh list-orphans` | `<n> orphan worktree dir(s)` | errors | `0` |

## Layout resolution contract

`worktree_lib_resolve_worktree_path` (in `lib/resolve-layout.sh`, entry scripts only) sets exported `WORKTREE_PATH`, `GIT_CONTEXT`, `HUB_ROOT`, `REPO_ROOT`. External callers use entry script flags, not lib globals.

Porcelain path equality uses `worktree_lib_normalize_scan_path` in `lib/path-key.sh` (`pwd -W` on Windows).

Fetch freshness marker (`lib/fetch-marker.sh`) mirrors `hook::fetch_marker_file` keying for `branch-awareness.sh`.

## Pipeline ownership

| Concern | Owner |
| --- | --- |
| Git worktree create / branch derive | `create-worktree.sh` |
| Session setup steps | `setup-worktree.sh` pipelines |
| Orphan advisory ctx line | `claude-session-start-worktree` pipeline (not hook) |
| Worktree session detection (main vs linked) | `claude-session-start` pipeline (`lib/resolve-layout.sh`) |
| Cross-worktree block diagnostic | `enforce-boundary.sh --emit-diagnostic` |

## Test gate scope

| Tier | Location | Verifier |
| --- | --- | --- |
| Lib unit | `lib/*.test.sh` | Source function libs; fast structural |
| Entry contract | `tools/worktree/*.test.sh` | Subprocess entry scripts |
| Hook integration | `.claude/hooks/worktree-*.test.sh` | Subprocess hook adapters + real git |
| Agent-loop | `prepare-workspace.test.sh` | End-to-end create + post-create |

Branch-name assertion set must match between `lib/branch-name.test.sh` and `worktree-create-branch-name.test.sh`.

## Operator commands

```bash
bash tools/worktree/worktree.sh setup --pipeline cursor
bash tools/worktree/worktree.sh create --name feat/foo --cwd .
bash tools/worktree/worktree.sh list-orphans --cwd .
```

## Environment variables

| Variable | Used by |
| --- | --- |
| `ROOT_WORKTREE_PATH` | Cursor adapter — main checkout for include copy source |
| `BOOTSTRAP_SH` | Tests — override bootstrap script path |
| `GIT_BIN` | Tests — override git binary |

## Plugin migration north star

Future `platform-worktree` plugin hooks delegate to `${CLAUDE_PROJECT_DIR}/tools/worktree/*` — this unit stays authoritative; plugins never duplicate git logic. Hook-migration research: `git log -- .work/skill-plugin-packaging/research/hook-migration.md`.
