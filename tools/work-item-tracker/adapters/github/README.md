# GitHub adapter — operations reference

Concrete `gh` mechanics for the `/work-items` skill's **non-coordination** operations against
the GitHub provider. Coordination (create / claim / lease / link / frontier) runs through the
seam verbs (`work-item-tracker.sh <verb>`, see `../../CONTRACT.md`); the operations below —
listing with arbitrary filters, search, aggregation, close, label/comment edits — have no core
verb by design (`docs/adr/0022-tracker-native-planning-behind-provider-seam.md`; DD2), so the
skill core describes them neutrally and resolves the mechanics here.

Base command shapes are owned by `docs/conventions/github-ops.md` (the repo-wide `gh` SSOT) —
each operation below **cites** its heading and layers only the work-items-specific
`--json`/`--jq` projection on top. Reads use bare `gh`; writes route through
`tools/github-auth/gh-bot.sh` where present (identity policy: `github-ops.md` "Bot identity";
seam identity routing: `../../CONTRACT.md` "Identity routing (GitHub adapter)"). Every pipeline
parsing `gh` JSON on Windows/Git Bash ends with `| tr -d '\r'` (see "Gotchas").

## Available `--json` fields

Do NOT hardcode the field set — GitHub adds fields over time (the dependency/parent/sub-item
fields the seam's normalized model reads — `blockedBy`, `parent`, `subIssues` — are recent
additions). Derive the current valid set on demand: `gh issue list --json` (no value) prints it.

## Resolve item ID

Seam verbs (`get-item`, `claim`, `reclaim`, `link-blocks`, `add-sub-item`) take a
fully-qualified ID (`github:<owner>/<repo>#<N>` — CONTRACT.md "ID grammar"); a bare `#N` is
rejected. The **seam** verbs (`list-frontier`, `get-item`, `create-item`) already emit the
qualified `id` — pass it straight through. The adapter's raw `list` / `search` projections below
emit only `number`, so build the qualified ID from the number:

```bash
PREFIX="$(gh repo view --json owner,name -q '"github:\(.owner.login)/\(.name)"' | tr -d '\r')"
ID="${PREFIX}#<N>"
```

## List items

Per github-ops.md "List issues" (bare `gh`). Arbitrary filter projection:

```bash
gh issue list \
  ${LABEL:+--label "$LABEL"} \
  ${ASSIGNEE:+--assignee "$ASSIGNEE"} \
  ${SEARCH:+--search "$SEARCH"} \
  --state "${STATE:-open}" \
  --json number,title,state,labels,assignees,createdAt,updatedAt \
  --limit "${LIMIT:-30}" \
  | tr -d '\r'
```

Forward `--assignee` for the `list --assignee` flag and the audit's assigned-only view (use
`--assignee "@me"` for the current user). `--limit` is mandatory when more than 30 rows are
needed (`gh` truncates at 30 silently; max page size 100 — for larger sets, page with `--search`
date ranges).

## Search items

Per github-ops.md "List issues" with `--search` (GitHub search syntax, not `gh` flags):

```bash
gh issue list --search "<query>" --state open   --json number,title,state,labels,assignees --limit 20 | tr -d '\r'
gh issue list --search "<query>" --state closed --json number,title,state,labels,closedAt   --limit 10 | tr -d '\r'
```

Search-qualifier reference:

| Qualifier | Example | Meaning |
|-----------|---------|---------|
| `label:name` | `label:type:chore` | Has label |
| `-label:name` | `-label:stale` | Excludes label |
| `no:assignee` | `no:assignee` | Unassigned |
| `assignee:login` | `assignee:@me` | Assigned to user |
| `sort:field-dir` | `sort:created-asc` | Sort (created, updated, comments) |
| `created:>date` | `created:>2026-01-01` | Created after date |
| `updated:>date` | `updated:>2026-03-01` | Updated after date |
| `"exact phrase"` | `"fix authentication"` | Body/title text search |

Multiple qualifiers AND-combine: `label:type:chore label:recurring no:assignee sort:created-asc`.

## View item

Per github-ops.md "View issue" (bare `gh`):

```bash
gh issue view <N> --json number,title,body,labels,assignees,comments | tr -d '\r'
```

Assignee/label projection for claim pre-checks:

```bash
gh issue view <N> --json assignees,labels \
  --jq '{assignees: [.assignees[].login], labels: [.labels[].name]}' | tr -d '\r'
```

## List item comments

Per github-ops.md "List issue comments" (bare `gh`):

```bash
gh api "repos/{owner}/{repo}/issues/<N>/comments" \
  --jq '[.[] | {id, user: .user.login, created_at, body}] | sort_by(.id)' | tr -d '\r'
```

## Close item

Per github-ops.md "Close issue" (WRITE via `gh-bot.sh`):

```bash
bash tools/github-auth/gh-bot.sh issue close <N> --comment "<closing note>" --reason completed
```

The `done` action closes with `--reason completed` (or `not planned` for `--not-planned`). The
full value set is owned by github-ops.md "Close issue".

## Edit labels / assignees

Per github-ops.md "Edit issue (labels / assignees)" (WRITE via `gh-bot.sh`). Edits use
`--add-label`/`--remove-label` and `--add-assignee`/`--remove-assignee` (NOT `--label`, which
is `gh issue create` only):

```bash
bash tools/github-auth/gh-bot.sh issue edit <N> --add-label "<name>" --remove-label "<name>"
```

**Carve-out — claim assignment stays on bare `gh`:** `--add-assignee "@me"` MUST resolve to the
session identity (not the bot), so it runs on bare `gh` per the github-ops.md heading's
carve-out. Coordination claims go through the seam `claim` verb, which owns this.

## Comment on item / edit a comment

Comment per github-ops.md "Comment on issue"; edit (PATCH, preserves audit trail) per
github-ops.md "Edit a comment" — both WRITE via `gh-bot.sh`:

```bash
bash tools/github-auth/gh-bot.sh issue comment <N> --body "<text>"
bash tools/github-auth/gh-bot.sh api --method PATCH "repos/{owner}/{repo}/issues/comments/<CID>" -f body="<text>"
```

## PR closing-keyword mechanics

For the `done` action's belt-and-suspenders keyword check. Read the PR body per github-ops.md
"View PR" (bare `gh`); the read-modify-write body edit uses github-ops.md "Edit PR body"
(`--body-file` REPLACES the body; WRITE via `gh-bot.sh`):

```bash
gh pr view <PR> --json body,mergedAt --jq '.body' | tr -d '\r' > /tmp/pr-body.md
# On an UNMERGED PR lacking a closing keyword and an opt-out marker, prepend `Closes #<N>`:
printf '%s\n\n%s\n' "Closes #<N>" "$(cat /tmp/pr-body.md)" \
  | bash tools/github-auth/gh-bot.sh pr edit <PR> --body-file -
```

Match the closing-keyword set (owned by github-ops.md "Closing keyword") followed by `#<num>`;
the opt-out markers `Refs #<num>` / `No related issue:` leave the body untouched.

## Aggregate / count (dashboard + hygiene)

`gh issue list --json ... --jq` projections for `stats` and `audit`. Per github-ops.md
"List issues" (bare `gh`).

Category counts:

```bash
gh issue list --state open --json labels --limit 500 --jq '
  [.[].labels[].name] | map(select(startswith("category:"))) | group_by(.) | map({key: .[0], count: length}) | sort_by(.key)
' | tr -d '\r'
```

Claimed/unassigned counts — a seam claim is an **assignee** (+ lease), so count assignees, NOT
the retired `status:claimed`/`status:considering` labels (which the seam never sets):

```bash
gh issue list --state open --json assignees --limit 500 --jq '
  { total: length,
    claimed: [.[] | select(.assignees | length > 0)] | length,
    unassigned: [.[] | select(.assignees | length == 0)] | length }
' | tr -d '\r'
```

Unlabeled (missing `type:`/`category:`) and priority-conflict projections:

```bash
gh issue list --state open --json number,title,labels --limit 100 --jq '
  [.[] | select(
    (any(.labels[]; .name | startswith("type:")) | not) or
    (any(.labels[]; .name | startswith("category:")) | not)
  ) | {number, title, labels: [.labels[].name]}]
' | tr -d '\r'

gh issue list --state open --json number,title,labels --limit 100 --jq '
  [.[] | select(([.labels[].name | select(startswith("priority:"))] | length) > 1)
       | {number, title, priorities: [.labels[] | .name | select(startswith("priority:"))]}]
' | tr -d '\r'
```

Stale-claim detection is NOT a label/date query — a claim is a lease, so the `audit` action
runs the seam `reclaim` verb over assigned items (CONTRACT.md "Lease protocol").

## Gotchas

Per-operation gotchas live with their sections above (the `--limit` truncation under "List
items", the `--add-label`-vs-`--label` rule under "Edit labels / assignees"). Cross-cutting:

- **Windows `\r`.** Git Bash adds `\r` to `gh` output through `jq`/`--jq`; end every parsing
  pipeline with `| tr -d '\r'` (`docs/claude-code/claude-code-quirks-reference.md` "Windows/Git
  Bash CR in pipe output").
- **Rate limits** (verify current values via GitHub REST docs): batch bulk creates to respect
  the secondary content-generation limit — e.g. 30 items per batch with short pauses.
- **Issue Forms auto-labeling** (`issue-labeling.yml`) fires only on web-form creation, not
  `gh issue create` — apply labels explicitly when creating programmatically.
