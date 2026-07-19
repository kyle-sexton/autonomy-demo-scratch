# Comment hygiene patterns

Shared detection patterns for inline comment discipline: actionable warning markers (`TODO`, `FIXME`, `HACK`, `XXX`) and **internal** tracker provenance in source comments.

**Consumers:** `.lefthook/pre-commit/comment-hygiene-check.sh`, `/work-items scan` remediation, `scan-tree.sh` (full-tree audit).

## Full-tree audit

```bash
bash tools/shared/comment-hygiene/scan-tree.sh
```

Fast path: one `git grep` coarse pass over tracked scannable files (with `should_skip_path` exclusions), then `chp::scan_text` per hit line. Completes in seconds — do **not** loop `chp::scan_file` over `git ls-files` or `find` (O(files × lines × greps); minutes+ on Windows).

Exit `0` = clean (`comment-hygiene scan-tree: clean` on stderr); `1` = violations on stdout as `path:lineno:kind:detail`.

**SSOT:** `review/code-quality.md` "Comments and self-documenting code".

**Kill switch:** `HOOK_COMMENT_HYGIENE_CHECK_ENABLED=false` (lefthook lane). **Advisory downgrade:** `HOOK_COMMENT_HYGIENE_BLOCKING=false`.

## Internal vs external references

| Class | Examples | Verdict |
| --- | --- | --- |
| **Internal tracker provenance** | `cc-issue #N`, `issue #42`, `fixes #42`, `PR #831`, `melodic-software/medley#42` | **Ban** — git/PRs/issues own history |
| **External upstream citations** | `dotnet/roslyn#24319`, `testcontainers-dotnet#1220`, `anthropics/claude-code#11897`, `cli/cli #11059`, bare `#39702` (Claude Code) | **Allow** — documents upstream root cause |
| **Work-artifact phase grammar** | `DONE+DOING+TODO`, `[TODO] phase`, `Phases: …` | **Allow** — state tokens, not actionable debt |
| **Actionable debt markers** | `// TODO: wire real sender`, `# FIXME:` | **Ban** — file a GitHub issue or fix now |

Detection is deterministic: internal repo slug denylist (`melodic-software/medley`, `melodic/medley`); lowercase `issue`/`fixes`/`closes`/`tracked:` + number; all `PR #N`; all `cc-issue`. External `org/repo#issue` passes when org/repo is not this repository.
