# node-runtime

fnm (Fast Node Manager) install for CI and cloud-setup. Idempotent `install-fnm.sh` (symlinks fnm into `/usr/local/bin` via upstream installer's `--skip-shell`) + sibling test.

Owner: joint-consumer — no single skill owns it; `shell-lint.yml` CI, MCP launcher fnm-exec spawn, and cloud-setup all depend on it. Consumers derive on demand via repo dep-graph edge scan (`tools/AGENTS.md` "Vertical slices").
