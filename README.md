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
  complete drain runs (read-only reporter). Runs listed in
  `run-corrections.jsonl` are excluded from its input set.
- `attest-fire-origin.sh` — fails-closed attestation of a drain run's fire
  origin, reconstructed from evidence the agent cannot write: outer-session
  transcript enqueue records + cron-slot alignment for `scheduled-*` runs,
  and the label-kick relay workflow's platform run record for `labeled-*`
  runs (scratch#42). `manual-*` never attests.
- `backup-evidence.sh` — snapshots the evidence surfaces to a timestamped
  backup folder and prunes to the last N snapshots.
- `watch-demotion.sh` — post-merge demotion net: gate re-check on drained
  merges plus revert scan, appends `demotion-events.jsonl`, fail-closed.
  Events the operator has dispositioned in `demotion-acks.jsonl` are still
  reported but no longer force a non-zero exit.
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
- `demotion-acks.jsonl` — operator dispositions of those events. Hand-
  maintained: no script writes it. Append one object per acknowledged event,
  keyed on the same `(kind, merge_sha)` pair the event carries, with
  `disposition_url` pointing at the judgement of record (the issue comment
  disposing of it). `watch-demotion.sh` keeps reporting an acknowledged event
  and never deletes its row; it only stops counting it toward the contrary
  total that forces exit 1, so one dispositioned false positive cannot bury a
  real second event under a permanently red watcher. Unacknowledged events
  keep failing loud, and a malformed file — or a row whose `disposition_url`
  is not an `http(s)` link once surrounding whitespace is trimmed (absent,
  empty, blank, or any other non-URL value) — fails closed like the events
  file: a disposition nobody can read is not a disposition.

  ```sh
  jq -cn --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{acknowledged_at: $d,
    kind: "gate-regression", merge_sha: "<full merge sha>",
    disposition_url: "<url of the comment disposing of it>"}' \
    >>.artifacts/demotion-acks.jsonl
  ```

- `run-corrections.jsonl` — runs whose PR needed a delegated pre-merge
  correction (a fix the verifying session made to the drain's output before
  merge). Hand-maintained: whoever makes the correction appends the row, at
  correction time; no script writes it. The C2 predicate's completion
  definition is claim→implement→PR with no help, so `predicate-c2.sh`
  excludes these runs from its **input set** — every aggregate (completion
  count, window span, gate pass rate, revert count) then computes over
  genuinely autonomous completions only. An unreadable file, or a row whose
  `run_id` cannot be applied — absent, empty, or naming a run no joined row
  carries (a typo) — fails closed rather than degrading to "nothing was
  corrected".

  ```sh
  jq -cn --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{corrected_at: $d,
    run_id: "<run_id from the return-accounting record>",
    pr_url: "<the corrected PR>", detail: "<what was corrected>"}' \
    >>.artifacts/run-corrections.jsonl
  ```
