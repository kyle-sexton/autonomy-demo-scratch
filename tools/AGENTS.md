# Tooling Codex Notes

Follow the root `AGENTS.md` first. These notes narrow that guidance for work under `tools/`.

## Directory layout

Three tiers: **entry** (stable public CLI at `tools/*.sh`), **slice** (vertical concern), **lib** (shared logic for 2+ consumers). Slice folders name the operator concern or mini-app — not language or framework.

Normative anatomy (full model + per-kind surface table: `docs/conventions/unit-anatomy.md`):

- **`lib/` is marked-private at any nesting depth** — nothing outside a unit references `<unit>/lib/`; all other subdirectories are default-private.
- **Contract surface** = root role-named entry scripts (shebang, `--help`, sibling test) + root sourceables without shebang (`# shellcheck shell=bash` directive, sibling test). External references target contract surfaces only; mini-apps publish their manifest instead.
- **Shared tier** — `tools/shared/<capability>/` holds capabilities with no single natural owner; capability-based naming, ownership-test promotion, and low-ceremony demotion per `docs/conventions/unit-anatomy.md` "Shared-tier governance".
- **One-way dependency direction** — units → shared; shared → shared; never shared → unit.

### Slice entry naming

- **Folder** = concern or product (`mcp-launcher/`, `code-review-context/`, `worktree/`).
- **Entry file** = role or behavior (`launcher.js`, `setup.sh`) — never repeat the folder slug in the filename.
- **Do not use** `index.js` in `tools/` slices (library barrel convention; poor grep specificity).
- **Qualifiers stay in the filename** when they disambiguate scope or enable growth (`setup-cursor-worktree.sh`, `codex-cloud-setup.sh`) — drop only the redundant folder-echo segment, not meaningful product/platform tokens.
- **Tests** inside a slice: behavior-named shards (`npx-dispatch.test.sh`), not folder-prefixed echoes (`mcp-launcher-npx.test.sh`).

### Entry points (`tools/*.sh`)

| Script | Purpose |
|--------|---------|
| `bootstrap.sh` | Prerequisite detect/fix for onboarding and worktree setup |
| `repo-grep.sh` | Scoped content search for audits (git grep / rg); see `docs/conventions/search-hygiene.md` |
| `run-shell-tests.sh` | Stable wrapper → `shell-test-runner/run.sh` |
| `measure-clear.sh` | `/clear` SessionStart hook timing probe |
| `resolve-memory-dir.sh` | Claude Code memory-dir resolver (bare-clone-hub-aware) |
| `list-project-skills.sh` | `.claude/skills/` frontmatter index for Cursor parity (`--tsv` optional) |

### Vertical slices

| Directory | Purpose |
|-----------|---------|
| `agent-loop/` | Headless implement-only agent loop (Docker + Cursor CLI mini-app) |
| `cloud-setup/` | Cloud and Codex environment bootstrapping |
| `code-review-context/` | Git facts for `/quality-gate` and `/code-review-fanout` (`emit-git-facts.sh`) |
| `corpus-extract/` | Content-domain corpus extraction (out of harness layout scope) |
| `dep-graph/` | On-demand dependency edge-list (`derive-dep-edges.sh` → TSV `from⇥kind⇥target`, kinds `source`/`exec`/`cite`); no stored graph |
| `desktop-mcp/` | Windows desktop MCP install helpers |
| `github-auth/` | JIT GitHub bot identity (`gh-bot.sh`, token generation) |
| `github-events/` | GitHub watcher + webhook broker lifecycle |
| `markdown-coupling/` | Doc coupling / citation machinery (`markdown-coupling.sh` dispatcher) |
| `model-routing/` | Cross-tool routing — catalog sync (cursor, codex), `routing.json` apply, AFK facade (`route-for-surface.sh`) |
| `perf/` | Shell spawn benchmark + Windows Git Bash tuning |
| `shell-test-runner/` | `*.test.sh` discovery runner implementation + self-tests |
| `skill-contract/` | Skill-governance contract gates (encapsulation, portability, script-contract) + shared frontmatter/portability helpers + deny-list |
| `skill-verify/` | Static gate for skill rewrite pass (`check-skill.sh`) |
| `verification/` | Repo-wide path hygiene + CLI flag checks |
| `work-artifacts/` | `.work/<slug>/` convention helpers + work-encapsulation gate |
| `codebase-audit/` | Audit target enumeration |
| `lint/` | Lint dispatch |
| `tidy/` | Tidy PR backlog and lane anchor facts |
| `worktree/` | Git worktree SSOT (`create-worktree.sh`, `setup-worktree.sh`, `enforce-boundary.sh`, `worktree.sh`; Cursor adapter `setup-cursor-worktree.sh`) |

### MCP (sibling slices — do not merge)

| Directory | Role | Runtime? |
|-----------|------|----------|
| `mcp-launcher/` | Cross-platform MCP stdio spawn (`launcher.js`, `dispatch.js`; MCP hosts use `fnm exec`); wired in `.mcp.json`, `.cursor/mcp.json`, `.codex/config.toml` | Yes |
| `mcp-parity/` | Read-only MCP config drift validators (Python); CI + local verify | No |

### Ecosystem exceptions (CI boundary, not feature slices)

| Directory | Purpose |
|-----------|---------|
| `dotnet/` | .NET build binlog + public API promotion |
| `powershell/` | PSScriptAnalyzer + Pester for `tools/**/*.ps1` |
| `typescript/` | TypeScript CI package discovery (`list-ci-packages.sh` → `typescript-ci.yml`) |

### Shared tier (`tools/shared/<capability>/`)

Capabilities with no single natural owner; governance per `docs/conventions/unit-anatomy.md` "Shared-tier governance". Each capability README names its owner.

| Directory | Purpose |
|-----------|---------|
| `shared/comment-hygiene/` | Actionable debt markers + internal tracker provenance detection (`comment-hygiene-patterns.sh`, `scan-tree.sh`) for lefthook + CI |
| `shared/eol/` | Line-ending normalization |
| `shared/node-runtime/` | fnm (Fast Node Manager) install for CI + cloud-setup |
| `shared/path-detection/` | Hardcoded machine-path pattern detection |
| `shared/pester/` | Pester workflow annotation helper |
| `shared/process-management/` | PID file read/write + graceful stop |
| `shared/repo-analysis/` | Git-repo structure/framework/section-diff analysis for `/youtube` + `/course-digest` (`@melodic/repo-analysis` package) |
| `shared/video-digestion/` | Video/transcript digestion kernel for `/youtube` + `/course-digest` (mini-app) |

### Data artifacts

| Directory | Purpose |
|-----------|---------|
| `schemas/` | Vendored JSON schemas (lefthook, onboard catalog, evals) |

## Required context

- CC OTEL capture: invoke `/claude-ops:claude-observability`. Hooks/CI cite the `tools/observability/start-{collector,dashboard}.sh` entry scripts (flat tools-unit root — the query/prune read-side is owned by the claude-ops plugin, not vendored here).
- Read `.claude/rules/bash/conventions.md` before changing shell scripts.
- Read `.claude/rules/powershell/conventions.md` before changing PowerShell scripts.
- Read `.claude/rules/hooks/conventions.md` when a script is called by hooks or agent workflows.
- Read `.claude/rules/shared-code-conventions.md` for share-vs-duplicate placement decisions.

## Implementation rules

- Keep scripts cross-platform unless the filename or docs clearly scope them to one OS.
- Do not embed one language inside another; extract non-trivial cross-language logic into a co-located file.
- Add or update script tests for behavior changes. Prefer the existing `*.test.sh` pattern and `tests/shell/lib.sh` helpers.
- Use explicit names for scripts, flags, environment variables, and output labels.
- Keep setup scripts idempotent and safe to rerun.

## Verification

- Run the relevant script test directly and `bash tools/run-shell-tests.sh` when touching shared shell behavior.
- Run `shellcheck <script>` and `shfmt -d <script>` for changed shell scripts.
