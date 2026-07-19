You are implementing Phase {{PHASE}} of the {{SLUG}} slice autonomously.

Apply: .work/{{SLUG}}/research/implement-shared-rules.prompt.md

READ FIRST: .work/{{SLUG}}/PLAN.md Phase {{PHASE}}, README.md, {{OUT_SUBDIR}}/

PHASE {{PHASE}} — <fill: phase title from PLAN>

PRE-FLIGHT:
<fill: blocked gates — e.g. user git mv before agent runs>

GOAL:
<fill: machine-checkable artifacts from PLAN sanity check>

ALLOWED WRITES: <fill: paths from PLAN phase scope, plus .work/{{SLUG}}/DEVIATIONS.md and {{OUT_SUBDIR}}/>

SENTINEL (final line only — do not repeat promise tags elsewhere in your reply):
Emit CONTINUE promise token when work remains.
Emit NO_MORE_TASKS promise token when GOAL satisfied or blocked gate fired.
Format per tools/agent-loop/prompt-authoring.md sentinel contract.

VERIFICATION (host — not in container):

- Operator runs: bash .work/{{SLUG}}/scripts/verify-phase-{{PHASE}}.sh
- Do not mark [DONE] or write phase-{{PHASE}}.done until GOAL artifacts exist on disk.
