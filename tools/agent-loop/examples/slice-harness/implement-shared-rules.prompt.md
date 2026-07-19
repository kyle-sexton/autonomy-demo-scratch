Shared rules for all {{SLUG}} agent-loop implement prompts.

IMPLEMENT-ONLY:

- Do NOT plan, research, architect, or expand scope beyond the active phase.
- Execute ONLY the phase named in the phase prompt.

GIT (user-owned):

- NEVER git add, commit, push, branch, checkout, switch, stash, or mv.
- Read-only git allowed for self-verification: `git status --short`, `git diff --stat HEAD`.
- If PRE-FLIGHT requires git mv, write the blocked marker and stop — do not proceed.

HOST VERIFICATION (thin container):

- Do NOT run npm, npx, vitest, dotnet, biome, yt-dlp, ffmpeg, or magick.
- Orchestrator may run a host verify script after the loop when `AGENT_LOOP_HOST_VERIFY_SCRIPT` is set.

MISSING CAPABILITY (stop and report):

- If a GOAL step needs tooling absent from the thin container (see docs/adr/0013-agent-loop-thin-container-images.md), do NOT improvise or claim done.
- Write {{OUT_SUBDIR}}/phase-N.blocked with: missing tool, why needed, suggested elevation.
- If Write/Edit is hook-blocked twice on the same path, stop and write blocked marker.
- Emit NO_MORE_TASKS only when GOAL is satisfied OR a blocker file exists on disk.

FILE WRITES (scope + path hygiene):

- Write ONLY under paths listed in the phase ALLOWED WRITES block (which includes .work/{{SLUG}}/DEVIATIONS.md and {{OUT_SUBDIR}}/).
- Prefer the file edit tool for content.
- NEVER create files at repo root (`/workspace/` top level).

DIVERGENCE (conservative-continue):

- If reality diverges from the plan but the phase's core assumption holds, pick the conservative option, log it in .work/{{SLUG}}/DEVIATIONS.md, and continue.
- If a fundamental assumption is wrong, write {{OUT_SUBDIR}}/phase-N.blocked and stop — do not redesign mid-loop.

SELF-VERIFICATION (required before NO_MORE_TASKS):

1. Run `git status --short` and `git diff --stat HEAD`.
2. Fail if any untracked file exists at repo root.
3. Write {{OUT_SUBDIR}}/phase-N.self-check.md with pass/fail per check.
4. Write {{OUT_SUBDIR}}/phase-N.done only when self-check passes.

PROGRESS:

- READ FIRST: .work/{{SLUG}}/PLAN.md (active phase), README.md, {{OUT_SUBDIR}}/
- Tick checklist items; do NOT flip phase header [TODO]→[DONE] (operator-only after host verify).

SENTINEL (final line of your response ONLY):

- Work remains: emit CONTINUE promise token (per prompt-authoring.md)
- GOAL satisfied OR blocked: emit NO_MORE_TASKS promise token

HONESTY:

- Emit NO_MORE_TASKS only when phase-N.done AND phase-N.self-check.md exist (or blocked marker per PRE-FLIGHT).
