# Agent-loop slice harness naming

Canonical artifact names for `.work/<slug>/` agent-loop pilots. Scaffold with `tools/agent-loop/scripts/scaffold-slice-harness.sh`; tailor `<fill: …>` bodies per PLAN — do not rename files.

| Role | Path | Notes |
|------|------|-------|
| Shared implement rules | `research/implement-shared-rules.prompt.md` | Cited from every phase prompt |
| Phase implement prompt | `research/implement-phase-{N}.prompt.md` | `{N}` = PLAN phase number |
| Operator run entry | `scripts/run-phase.sh` | Sets `RALPH_OUT_SUBDIR`, `AGENT_LOOP_RUN_ID` |
| Verify helpers | `scripts/verify-common.sh` | Shared assert helpers |
| Phase host verify script | `scripts/verify-phase-{N}.sh` | PLAN sanity check for phase N |
| Completion marker | `out/phase-{N}.done` | One-line summary |
| Blocked gate | `out/phase-{N}.blocked` | PRE-FLIGHT or missing capability |
| Elevation report | `out/needs-elevation.md` | Optional cross-phase blocker |
| Pilot audit | `research/agent-loop-pilot-audit.md` | Per-phase tool/feature notes |
| Run id | `AGENT_LOOP_RUN_ID={slug}-p{N}` | Log folder label |

Philosophy: `tools/work-artifacts/scaffold-artifact.sh` — script the mechanical, keep judgment human.
