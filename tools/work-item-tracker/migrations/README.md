# status-label migration — `migrate-blocked-labels.sh`

Retires the two label-encoded status models to their native replacements, per the locked
governance in EPIC melodic-software/medley#1491 and `docs/conventions/issue-labels.md`
"Two status models that are not labels":

- `status: blocked` → **native blocked-by edge** (an issue is blocked iff it has an open
  blocked-by edge).
- `status: claimed` → **assignee + lease comment** (the claim is the assignee plus a
  `claimed:`/`released:` lease trail).

This is slice **S7** of the EPIC (issue #1339 / Phase 5 of map #1334). The PR ships tooling and
docs only. Every live mutation — running `--apply`, deleting labels, editing the live EPIC #1273
body — is a **gated, human-run post-merge step** (see "Post-merge runbook" below).

## The script

`migrate-blocked-labels.sh` — `--dry-run` is the DEFAULT and is strictly read-only.

```text
migrate-blocked-labels.sh [--dry-run|--apply|--verify] [--repo <o>/<r>] [--limit <n>] [--reify-external]
```

| Mode | Effect |
|---|---|
| `--dry-run` (default) | Read-only. Phase-entry marker check, then emit the full proposed migration set for owner review. Mutates nothing. |
| `--apply` | GATED live migration: create native edges, remove per-issue labels (with a migration comment), delete the retired label definitions once unreferenced. |
| `--verify` | Read-only post-migration sanity checks. |

Design guarantees:

- **Idempotent.** Edges already present are skipped; labels already absent are skipped;
  re-running `--apply` converges.
- **Never disrupts in-flight work.** An issue with an open cross-referenced PR or an active
  (not-yet-released) lease comment is `SKIP-INFLIGHT`: no edge is added (never retro-block),
  no `status: claimed` is cleared.
- **Never loses a dependency.** An issue whose only blocker is an unresolved external phrase
  or an unparseable body keeps its `status: blocked` label; label *definition* deletion is
  refused while any issue still carries the label.
- **Sanity discipline (R14/R4).** Every existence check separates provider/fetch failure from
  no-match: a non-zero `gh label list` / `gh issue list` exit **FAILS** the check (it is never
  read as "clean/absent"); enumeration uses `--limit 200`, beating gh's silent 30-row default.
- **External blockers are review-only by default.** Body prose like "…depends on EVERY cutover
  issue…" is a common false-positive, so external phrases are reported for review and the
  label is retained. `--apply --reify-external` converts owner-vetted external blockers into
  `wayfind: task` items with an edge.

### Phase-entry marker check (governance note)

The check records which structural markers (`work-map`, `needs-human`, `wayfind:*`) already
exist (charting created them 2026-07-11) and **fails if any are missing** rather than creating
them. This is deliberate: per EPIC #1491, `melodic-software/github-iac` is the **sole label
writer** — a missing marker is provisioned through a github-iac PR (a `pulumi up` would prune
any ad-hoc label anyway). This supersedes the older PLAN wording "creates only missing".

### Tests

`migrate-blocked-labels.test.sh` unit-tests the pure logic — dependency-clause parsing (map
refs and prior-dep notes on the same line are correctly excluded) and the label-absence
verdict (the fetch-failure-is-never-clean crux). The gh-touching apply/verify paths mutate
shared coordination state, so they are exercised only against the live tracker under the gated
run, never in the offline suite.

## Post-merge runbook (GATED — human-run, in order)

> Serialized, never parallel on the shared live tracker. Present the dry-run set to the owner
> and get approval before any mutation.

0. **Confirm S5 (#1496 / PR #1503) is merged to `main`.** It introduces
   `docs/conventions/issue-labels.md` and `docs/conventions/worker-protocol.md`, which the doc
   edits below target. S7 is native-blocked-by #1496 for this reason.
1. **Apply the prepared doc edits** (below) to those two files on `main`:
   - Add the `wayfind:` extension policy to `issue-labels.md` (permanent taxonomy rule).
2. **Dry-run and review:** `migrate-blocked-labels.sh --dry-run` — walk the proposed set with
   the owner; decide any `EXTERNAL` / `NO-BLOCKER` items (reify, edit the body, or accept).
3. **Flip the #1273 body** to the prepared target text (below) — BEFORE any label deletion, so
   no in-flight worker reads a retired-label protocol.
4. **Apply:** `migrate-blocked-labels.sh --apply` (add `--reify-external` only for vetted
   external blockers). Creates edges, removes per-issue labels, deletes the label definitions
   once unreferenced. **Multi-pass by design:** in-flight items (open PR or active lease) keep
   their label and block label-definition deletion, so a first pass migrates everything
   resolvable and leaves the in-flight holdouts; re-run `--apply` after each holdout's PR
   closes to finish. On the live tracker at authoring time the holdouts were #1393 (open PR)
   and #1477 (claimed, open PR) — label deletion and a passing `--verify` are **deferred**
   until those resolve.
5. **Retire the transition notes** (below) in `issue-labels.md` and `worker-protocol.md` — do
   this step ONLY after the labels are actually deleted, so the docs never claim retirement
   before it is true.
6. **Verify:** `migrate-blocked-labels.sh --verify` passes **once the holdouts (step 4) have
   resolved and a final `--apply` pass has deleted the labels**; spot-check that migrated
   issues report `blockedBy.totalCount ≥ 1` (`gh issue view <n> --json blockedBy`); and
   `bash tools/repo-grep.sh 'status: (blocked|claimed)'` is clean outside journal/history exemptions
   (this migration's own `README.md` + script are retirement documentation/tooling, not stale
   consumers — the same category as `adapters/github/README.md`). The labels are also pruned
   by the S10 `pulumi up` (idempotent belt-and-suspenders).

---

## Prepared text: the #1273 worker-protocol flip

Apply these targeted replacements to the **live body of EPIC #1273** at gated step 3. They
retire the label mechanics only; the program-specific parts (eligibility marker
`plugin-migration + agent-ready`, self-merge authorization, `marketplace.json` merge protocol)
are unchanged. The canonical claim/execute/release procedure is
`docs/conventions/worker-protocol.md` — #1273 cites it rather than restating it.

**Dependency encoding** — REPLACE:

> Dependency encoding: `Depends on: #N` in body + `status: blocked` label. Every
> worker-executable issue carries `agent-ready` from creation; blocking is expressed ONLY via
> `status: blocked` — never by omitting `agent-ready` (an unblock must not require a second
> labeling step to become visible). `needs-human` issues with open dependencies ALSO carry
> `status: blocked` (both coexist).

WITH:

> Dependency encoding: a native **blocked-by edge** (`gh issue edit <n> --add-blocked-by <url>`,
> or the seam `link-blocks` verb). Every worker-executable issue carries `agent-ready` from
> creation; an issue is blocked iff it has an **open** blocked-by edge — never a label, so an
> unblock is automatic when the blocker closes (no second labeling step). `needs-human` issues
> may also have open blocked-by edges (the decision gate and the block coexist).

**Claim protocol** — REPLACE the label mechanics in steps 1–7 with the assignee+lease model
(full procedure: `docs/conventions/worker-protocol.md` "Claim protocol"): <!-- worker-protocol.md lands in S5 (#1496, PR #1503), unmerged; forward ref --> <!-- heading-cite-ignore-line -->

- Step 1 eligibility: "…WITHOUT `status: blocked` / `status: claimed` / `status: needs-decision`"
  → "…with **no open blocked-by edge**, **no assignee / active lease**, and without
  `status: needs-decision`." Same edit in the interview-pool fallback (drop the
  `status: blocked` / `status: claimed` exclusions; keep `needs-human` / `status: needs-decision`).
- Step 2 orphan/stale: "A `status: claimed` label with no active claim comment is ORPHANED" →
  "An **assignment** with no active lease comment is ORPHANED".
- Step 4 claim: "add `status: claimed` + comment `claimed: …`" → "**assign yourself** (`@me`),
  then comment `claimed: <worker-id> <ISO timestamp>`".
- Step 5 back-off: "remove `status: claimed` ONLY if no other active claim remains" →
  "**un-assign** only if no other active claim remains".
- Step 6 completion: "remove `status: claimed`, and remove `status: blocked` from any dependent
  whose dependencies are now all closed" → "**un-assign**; native blocked-by dependents
  **auto-resolve** on close — no label to clear".
- Step 7 early exit: "remove `status: claimed` unless another active claim exists" →
  "**un-assign** unless another active claim exists".

**Tracker hygiene on close** — REPLACE:

> 1. Remove `status: claimed` from the issue you close.
> 2. Find dependents: search open issues whose body contains `Depends on: #<your-issue>`; for
>    each whose `Depends on:` issues are now ALL closed, remove `status: blocked` and comment
>    `Unblocked: #<your-issue> closed`.

WITH:

> 1. Un-assign yourself from the issue you close.
> 2. Native blocked-by dependents auto-unblock when this issue closes (their open-blocker count
>    drops to zero). No label to remove; optionally comment `Unblocked: #<your-issue> closed`
>    on a dependent for the timeline.

**Escalation / interview-mode hand-off** — the label swaps "swap `status: claimed` for
`status: needs-decision`" become "**un-assign**, post `blocked:` / `released:`, and add
`status: needs-decision`" (the `status: needs-decision` and `needs-human` gate labels are
RETAINED — only `blocked`/`claimed` are retired).

**Labeling-per-rules note** (line ~56, emitter issues): "incl. `status: blocked` + `Depends on:`
where gated" → "incl. a **blocked-by edge** where gated".

---

## Prepared text: doc edits (target S5's files on `main`)

### `docs/conventions/issue-labels.md` — ADD the extension policy (gated step 1)

Append to the `wayfind:` axis entry under "Axes carried in this repo":

> - **`wayfind:`** — the investigation type a work item routes to. **Extension policy:** a new
>   `wayfind:` value may be added only when an existing routing target (a skill the type routes
>   to) already exists — the taxonomy never names a type with nowhere to go.

### `docs/conventions/issue-labels.md` — RETIRE the transition note (gated step 5, after deletion)

REPLACE:

> Both `status: blocked` and `status: claimed` labels still exist on the live tracker until the
> migration in #1339 retires them; treat this section as the target model and the migration as
> the mechanism.

WITH:

> `status: blocked` and `status: claimed` are retired (migrated to native edges + assignee/lease
> by #1339). The two models above are the only claim/block mechanism.

### `docs/conventions/worker-protocol.md` — RETIRE the transition note (gated step 5, after deletion)

In the "**Target-state form.**" paragraph, drop the caveat sentence:

> The live tracker still uses `status: claimed` / `status: blocked` labels until #1339 flips it;
> where a program's issue bodies still say "add `status: claimed`", follow the live tracker's
> current mechanism and read this file as the destination.

The protocol is then simply the live mechanism (no transition caveat).
