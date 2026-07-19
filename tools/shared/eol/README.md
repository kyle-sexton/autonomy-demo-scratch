# eol

Symmetric, idempotent EOL normalization driven by `git check-attr eol` (LF arm on every OS; CRLF arm self-gates to Windows). Sourceable `normalize-eol.sh` + sibling test.

Owner: editorconfig/EOL policy — `.claude/rules/editorconfig.md`. Consumers derive on demand via the repo dep-graph edge scan (`tools/AGENTS.md` "Vertical slices").
