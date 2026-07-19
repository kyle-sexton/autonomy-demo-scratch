# MCP launcher

Cross-platform stdio entry for `.mcp.json` npx and local `mcp-servers/` servers.

**Convention:** `docs/mcp/mcp-stdio-spawn.md` · **ADR:** `docs/adr/0014-mcp-stdio-fnm-launcher-spawn.md`

## Two layers (do not collapse)

| Layer | Binary | Role |
| --- | --- | --- |
| **Runtime bootstrap** | `fnm` | MCP hosts spawn `fnm exec --using=.nvmrc -- node …` so GUI apps get repo-pinned Node without shell profiles ([fnm exec](https://github.com/Schniz/fnm/blob/master/docs/commands.md#fnm-exec)) |
| **Package dispatch** | `launcher.js` | Windows-safe `npx` (`cmd /c`) or worktree-scoped repo server (`mcp-servers/<name>/node`) |

Bare `npx` in `.mcp.json` fails on Windows (`.cmd` without `shell: true`). Bare `node` fails in GUI hosts when Node is only on the login-shell PATH. **`fnm` on the OS User PATH** is the prerequisite — `bash tools/bootstrap.sh` and `/onboard fix` Phase 1 install and verify it.

## `.mcp.json` shape

```json
{
  "command": "fnm",
  "args": [
    "exec", "--version-file-strategy=recursive", "--using=.nvmrc", "--",
    "node", "tools/mcp-launcher/launcher.js",
    "-y", "@scope/package@pin"
  ],
  "env": { "MCP_LAUNCHER_FNM_ACTIVE": "1" }
}
```

`MCP_LAUNCHER_FNM_ACTIVE` tells `launcher.js` the parent already ran `fnm exec` (skip double-wrap). Manual dev: `fnm exec --using=.nvmrc -- node tools/mcp-launcher/launcher.js …` or set that env when testing.

## When MCP fails to connect

1. `bash tools/bootstrap.sh` (or `/onboard fix` Phase 1)
2. Restart the IDE after PATH changes
3. Onboard row **Node visible to GUI subprocesses** — probes `fnm exec` + `.nvmrc` via the same path MCP uses

See `docs/cursor/setup.md` and `.claude/skills/onboard/context/per-concern/runtimes.md` Gap 3a.

## Performance

MCP stdio servers are **long-lived** — hosts spawn them once per IDE session (or on toggle), not per tool call. Wrapper cost is **cold-start only**; steady-state tool latency is unchanged.

**Measured on Windows (representative; order of magnitude):**

| Step | Typical cost | Notes |
| --- | --- | --- |
| `fnm exec` vs bare `node` | **+20–50 ms** | Rust binary + version resolution; negligible vs MCP boot |
| `launcher.js` → `npx --version` | **~400–500 ms** | `cmd /c` + npx startup on Windows — required for cross-platform spawn |
| Repo mode `git rev-parse` | **~120 ms** | Once per repo-server start; worktree isolation |
| Real package (e.g. `@ccusage/mcp`) | **2–5+ s** | npm cache, package JS init, MCP `initialize` — dominates |

**Implications:**

- **`fnm exec` is not the bottleneck** — removing it saves tens of ms while breaking GUI PATH correctness.
- **`launcher.js` is not optional on Windows** for npx-backed servers — bare `npx` in `.mcp.json` fails without `shell: true`.
- **Prefer HTTP or native stdio** when latency matters and transport fits (`context7`, `nuget`, `aspire` skip this stack entirely).
- **Repo-local servers** (`github-events`) avoid npx download; keep `bash tools/bootstrap.sh` so `build/` exists (no cold `npx` fetch).
- **Second session start** is faster when npx/npm cache is warm — first install after pin bump is the slow path.

`fnm-exec-entry.test.sh` asserts the full `fnm exec` + `launcher.js --version` path stays under a generous budget to catch accidental double-wrap or extra shell hops.

## Tests

```bash
bash tools/mcp-launcher/npx-dispatch.test.sh
bash tools/mcp-launcher/repo-dispatch.test.sh
bash tools/mcp-launcher/fnm-exec-entry.test.sh
```
