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

- `drain-next.sh` — scheduled drain entrypoint (15-min slot grid); claims the
  first eligible C2-labelled open item via the tracker seam and dispatches it
  (`--dry-run` for a read-only preview).
- `dispatch-item.sh` — runs one agent session on an already-leased item in
  an isolated worktree, under a dollar/time budget; opens a PR and stops
  (never merges or closes).
- `verify-join.sh` — acceptance proof joining wrapper span, session
  telemetry, return-accounting record, deterministic-gate outcome, and PR
  merge state for one item+run.
- `predicate-c2.sh` — evaluates the C2 promotion predicate over all
  complete drain runs (read-only reporter).
- `attest-fire-origin.sh` — fails-closed attestation of a drain run's fire
  origin, reconstructed from evidence the agent cannot write: outer-session
  transcript enqueue records + cron-slot alignment for `scheduled-*` runs,
  and the label-kick relay workflow's platform run record for `labeled-*`
  runs (scratch#42). `manual-*` never attests.
- `backup-evidence.sh` — snapshots the evidence surfaces to a timestamped
  backup folder and prunes to the last N snapshots.
- `watch-demotion.sh` — post-merge demotion net: gate re-check on drained
  merges plus revert scan, appends `demotion-events.jsonl`, fail-closed.
- `detect-missed-fire.sh` — deterministic, zero-token missed-fire detector
  (Phase 2 item 4, re-specced against the bound 15-min slot grid per scratch#66;
  wiring into a live scheduled task stays Phase 4): scans outer-session
  transcript enqueue evidence for grid slots with no fire, and would file a
  human-gated tracker item per coalesced gap (`--dry-run` for a read-only,
  network-free preview).

Trigger surfaces (scratch#42): the label-kick surface is wired as far as the
platform allows today. `.github/workflows/label-kick.yml` receives
`issues.labeled` for the C2 label and records the platform-attested kick (the
workflow run itself: id, path, run-name-encoded issue + label, timestamps) —
it executes nothing. No push path reaches the local execution surface on any
current platform surface, so dispatch stays on the 15-min temporal grid; a
future push-capable hop fires `drain-next.sh --fire-kind labeled --kick-ref
<relay-run-id>`, whose completions attest via the relay record and surface in
the predicate output as `completions_labeled_attested` (eligibility widens to
them only at activation). One kick attests one run: a `kick_ref` recorded by
two runs — a retried dispatch delivery inside the join window — attests
neither, so a single event cannot be counted twice. Decisions, rejected
alternatives, and deferral triggers are recorded on scratch#42.

Evidence files under `.artifacts/`:

- `drain-runs.jsonl` — per-run drain state, written by `drain-next.sh`.
- `fire-attestations.jsonl` — recorded fire-origin attestations, appended
  by `attest-fire-origin.sh --record`.
- `demotion-events.jsonl` — post-merge demotion events, appended by
  `watch-demotion.sh`.
