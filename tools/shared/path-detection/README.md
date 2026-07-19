# path-detection

Hardcoded machine-specific path pattern detection (`hpp::scan_text` + per-OS pattern sets, optional `[file_path]` OS-context exemption arg). Sourceable `hardcoded-path-patterns.sh` + sibling test.

Owner: path-hygiene policy — `.claude/rules/bash/conventions.md` "OS-context exemption". Consumers derive on demand via the repo dep-graph edge scan (`tools/AGENTS.md` "Vertical slices").
