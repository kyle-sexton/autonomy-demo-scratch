# autonomy-demo-scratch

[![deterministic-gate](https://github.com/kyle-sexton/autonomy-demo-scratch/actions/workflows/gate.yml/badge.svg)](https://github.com/kyle-sexton/autonomy-demo-scratch/actions/workflows/gate.yml)

Standing autonomy proving ground (role ratified 2026-07-20, matching the GitHub
repo description): a neutral target for return-accounting / trigger-dispatch
demos, routine runs, and the eventual C2-promotion evidence drain.

The work-item-tracker seam (`tools/work-item-tracker/`, copied from a carrier
repo per its own install path) and a repo-local autonomy binding with a
`triggers` section live here.

Evidence: melodic-software/claude-code-plugins#356 and #372.

## autonomy-demo toolchain

`tools/autonomy-demo/` entrypoints:

- `drain-next.sh` — hourly drain entrypoint; claims the first eligible
  C2-labelled open item via the tracker seam and dispatches it (`--dry-run`
  for a read-only preview).
- `dispatch-item.sh` — runs one agent session on an already-leased item in
  an isolated worktree, under a dollar/time budget; opens a PR and stops
  (never merges or closes).
- `verify-join.sh` — acceptance proof joining wrapper span, session
  telemetry, return-accounting record, deterministic-gate outcome, and PR
  merge state for one item+run.
- `predicate-c2.sh` — evaluates the C2 promotion predicate over all
  complete drain runs (read-only reporter).
- `attest-fire-origin.sh` — fails-closed attestation of a drain run's fire
  origin (scheduled vs. manual), reconstructed from outer-session
  transcript evidence.
- `backup-evidence.sh` — snapshots the evidence surfaces to a timestamped
  backup folder and prunes to the last N snapshots.

Evidence files under `.artifacts/`:

- `drain-runs.jsonl` — per-run drain state, written by `drain-next.sh`.
- `fire-attestations.jsonl` — recorded fire-origin attestations, appended
  by `attest-fire-origin.sh --record`.
