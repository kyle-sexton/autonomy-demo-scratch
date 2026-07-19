# Claude Desktop MCP launchers

Tiny `.bat` wrappers that let Claude Desktop's `claude_desktop_config.json` use HTTP/SSE MCP servers (via [`mcp-remote`](https://github.com/geelen/mcp-remote)) without embedding API keys in the config file.

## Why

Claude Desktop's `claude_desktop_config.json` does NOT support `${VAR}` interpolation ([anthropics/claude-code#1254](https://github.com/anthropics/claude-code/issues/1254)). Any env-block value is a literal string. For `mcp-remote --header "x-api-key:..."`, the `...` part must be a literal too.

These wrappers read the key from the Windows User env (`%CONTEXT7_API_KEY%`, `%REF_API_KEY%`) and forward it to `mcp-remote` at launch time. The Desktop config just points at the `.bat`; the key never lands in the config file.

## Files

| File | Purpose |
|---|---|
| `install.ps1` | Builds the full 12-server `mcpServers` block + merges into `claude_desktop_config.json` (preserving existing `preferences`). Detects MSIX vs Win32 install. Writes a one-time canonical `.backup` (preserved across re-runs) plus a timestamped pre-write snapshot before any change. Runs a Preflight phase (variant detection, existing-config classification, path safety, backup integrity, smell test, prereq checks) — FAIL findings abort; WARN findings prompt (or abort under `-NonInteractive`). Tags every produced config with a `_managed_by` marker so future re-runs distinguish OUR-MANAGED from FOREIGN-OR-MERGED configs. Idempotent — re-run after Node bumps, repo relocations, or `.mcp.json` changes. |
| `verify.ps1` | Spawns each configured server with its EXACT config command + args + env (mirrors Desktop's CreateProcess semantics) and sends a real MCP `initialize` handshake. Outcome-driven verification — asserts on observable behavior (server responds with `result.protocolVersion`) not config-shape implementation. Distinguishes `PASS` / `OAUTH-PENDING` (first-run auth, complete in browser) / `FAIL`. Run after `install.ps1`. |
| `context7-launcher.bat` | Wraps [context7](https://github.com/upstash/context7) HTTP MCP with `x-api-key` header (via `mcp-remote`) |
| `ref-launcher.bat` | Wraps [ref.tools](https://ref.tools) HTTP MCP with `x-ref-api-key` header (via `mcp-remote`) |

## Prereqs

- `fnm` on persistent Windows User PATH (default winget-managed location at `%LOCALAPPDATA%\Microsoft\WinGet\Links`). Resolves Node dynamically via `fnm exec --using=default --`; no User PATH modification needed. Test: `cmd /c fnm exec --using=default -- cmd /c npx --version` should print the npm/npx version. This is the **fnm-documented** non-shell pattern ([`fnm exec`](https://github.com/Schniz/fnm/blob/master/docs/commands.md#fnm-exec)); contrast with appending `aliases\default` to User PATH (repo workaround for hardcoded `node` — see `.claude/skills/onboard/context/per-concern/runtimes.md` Gap 3a and `docs/cursor/setup.md`).
- `CONTEXT7_API_KEY` / `REF_API_KEY` set as Windows User env vars (`setx CONTEXT7_API_KEY <value>`).

## Use from Claude Desktop config

Use `install.ps1` in this directory — it builds the full 12-server `mcpServers` block (including these two launchers) and merges it into your Claude Desktop config preserving any existing `preferences`:

```pwsh
pwsh -NoProfile -File tools/desktop-mcp/install.ps1 -WhatIf            # dry run — runs preflight + prints merged JSON
pwsh -NoProfile -File tools/desktop-mcp/install.ps1                    # apply (interactive: prompts on WARN)
pwsh -NoProfile -File tools/desktop-mcp/install.ps1 -NonInteractive    # apply unattended (aborts on any WARN)
pwsh -NoProfile -File tools/desktop-mcp/verify.ps1                     # Tier 2: each server responds to MCP handshake
```

### Preflight

The script runs a Preflight phase before any write, emitting **PASS / WARN / FAIL** findings:

| Check | What it gates |
|---|---|
| `desktop-variant` | Selected variant + diagnostic (which Desktop dir exists, which doesn't). FAIL if no variant installed; WARN if both present |
| `asar-path-verify` | **Deep verify** — locates the MSIX Claude app's `app.asar`, extracts the `L_A` variant suffix (e.g. `-3p`), and FAILs if the resolved config path doesn't match the asar-derived expected dir. Catches the 2026-05-16 wrong-path incident at root. WARN if package/asar absent or asar minifier changed |
| `docs-freshness` | Active fetch of canonical `modelcontextprotocol.io/docs/develop/connect-local-servers`; WARN on 404 or missing `claude_desktop_config` mention (signals upstream restructure) |
| `existing-config` | 3-state: ABSENT / OUR-MANAGED (`_managed_by` marker present OR all 12 server keys match this script's set) / FOREIGN-OR-MERGED (WARN; lists extras + missing) |
| `path-safety` | Reparse-point detection on the target dir |
| `writable` | Probes write with a temp file (cleaned up via `try/finally`; bypasses `-WhatIf` to produce meaningful signal in dry-run) |
| `backup-integrity` | FAIL if existing `.backup` is recursively wrapped (`.mcpServers.mcpServers`); WARN if invalid JSON |
| `smell-test` | WARN on unexpected top-level keys outside `{mcpServers, preferences, _managed_by}` |
| `connector-overlap-*` | WARN for each server in `mcpServers` that overlaps with an Anthropic hosted Connector (currently: `granola`). Surfaces dual-client risk; user picks one |
| `prereq-*` | fnm on PATH, MCP build artifacts, `.bat` launchers, User env API keys (CONTEXT7, REF, PERPLEXITY) |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Preflight clear (or only PASS), write succeeded (or `-WhatIf` dry-run completed) |
| 1 | Preflight clear but write failed mid-flight |
| 2 | Preflight aborted (FAIL finding OR WARN under `-NonInteractive` OR user declined Y/N) |

### Verification tiers

Each tier rules out a different failure mode. Tier 1 + 2 are necessary but NOT sufficient — only Tier 3 proves Desktop actually loaded the config:

| Tier | Signal | Tooling | Catches |
|---|---|---|---|
| 1 | Config file is valid JSON at the resolved path | `install.ps1` Preflight + write | Schema corruption, recursive-backup |
| 2 | Each server's spawn command responds to MCP `initialize` | `verify.ps1` | Wrong `command`/`args`/env, PATH issues, missing builds |
| 3 | Desktop emits `%APPDATA%\Claude\logs\mcp-server-<NAME>.log` after full quit + relaunch | Manual — restart Desktop + check log dir | Wrong config FILE LOCATION (the 2026-05-16 incident — issue #919) |

The script:

- Detects whether Claude Desktop is the current Anthropic-branded "-3p" MSIX app (`%LOCALAPPDATA%\Claude-3p\`), classic Win32 (`%APPDATA%\Claude\`), or vestigial MSIX-virtualized — and targets the right path. The variant diagnostic in Preflight surfaces the "Claude-3p exists / Classic exists" probe explicitly so the next path-mismatch incident is one-log-read diagnosable.
- Resolves the repo's absolute path via `git rev-parse --show-toplevel` (portable across clone locations).
- Writes a canonical `.backup` of the prior config on first apply (preserved across re-runs) plus a timestamped pre-write snapshot before each subsequent write.
- Tags every produced config with `_managed_by: "tools/desktop-mcp/install.ps1"` so future re-runs distinguish OUR-MANAGED from FOREIGN-OR-MERGED configs.

Direct manual entry (if you'd rather not use the script):

```json
{
  "mcpServers": {
    "context7": {
      "command": "<absolute-path-to-this-repo>\\tools\\desktop-mcp\\context7-launcher.bat"
    },
    "ref": {
      "command": "<absolute-path-to-this-repo>\\tools\\desktop-mcp\\ref-launcher.bat"
    }
  }
}
```

Replace `<absolute-path-to-this-repo>` with the absolute path to this repository's working tree on the contributor's machine.

## Why this shape

Two constraints stack on Windows Claude Desktop:

1. `npx.cmd` cannot be spawned directly by `child_process.spawn` ([servers#3460](https://github.com/modelcontextprotocol/servers/issues/3460)) — needs `cmd /c npx ...`.
2. `npx` is not on persistent Windows User PATH when Node is installed via `fnm` (fnm uses session-multishell shims that only activate inside shells where `fnm env` ran). Desktop launched from Start Menu inherits the bare User PATH — no fnm shim.

`fnm exec --using=default -- cmd /c npx ...` solves both: `fnm` itself IS on persistent PATH (winget install) and activates the default Node version's directory in its child process's PATH, after which `cmd /c npx` resolves correctly.

Same `.bat` indirection also lets us read `%CONTEXT7_API_KEY%` / `%REF_API_KEY%` from inherited User env and forward as literal `--header` args, since Desktop's config file format has no `${VAR}` interpolation.

## Cross-reference

Full research, gotchas, and migration map: slice deleted post-merge per `work-artifacts/conventions.md` "Promotion paths" — retrieve via `git log -- .work/issues-work/mcp-desktop-parity/`.
