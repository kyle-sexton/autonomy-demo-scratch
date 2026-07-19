You are implementing one bounded chunk autonomously. Do NOT plan, research, or expand scope.

WORKSPACE: bind-mounted at /workspace (host path supplied by the operator).

READ FIRST:

- PLAN.md — execute ONLY the next [TODO] phase.
- out/ — list existing completion markers (if any).

GOAL (ground truth):

- Complete the scoped PLAN phase: allowed files updated, phase tag [DONE], README ## Status current when applicable.
- Write a completion marker file under out/ when the phase finishes (e.g. out/phase-complete.txt with a one-line summary).

THIS ITERATION:

1. Read PLAN.md and identify the single [TODO] phase in scope.
2. Implement only that phase — no drive-by refactors.
3. Update PLAN.md phase tag [TODO]→[DONE] when the phase completes.
4. Update README.md ## Status when the slice uses it.

ALLOWED WRITES: paths listed in the PLAN phase scope, plus DEVIATIONS.md and out/.

DIVERGENCE: if reality diverges from the plan but the phase's core assumption holds, pick the conservative option, log it in DEVIATIONS.md, and continue. If a fundamental assumption is wrong, write out/phase-N.blocked and stop — do not redesign mid-loop.

When more work remains after this iteration: <promise>CONTINUE</promise>
When GOAL is fully satisfied on disk: <promise>NO_MORE_TASKS</promise>

VERIFICATION (required before NO_MORE_TASKS):

- Run: dotnet test --project <tests-project-path>
  (Operator substitutes the test project for the slice — e.g. the module's cross-cutting test project under tests/.)
- Pass: exit code 0 AND PLAN.md scoped phase tag is [DONE] AND out/ completion marker exists
- Fail: fix and emit CONTINUE

Notes for operators:

- Thin agent-loop images cannot run dotnet inside the container today — run this loop against a **fat devcontainer image** OR treat verification as a **host post-hook** after the loop exits (see docs/adr/0013-agent-loop-thin-container-images.md).
- Prefer `role: "implement"` or explicit model in run.local.json; raise maxIterations for multi-iteration slices.
