#!/usr/bin/env bash
# migrate-type-labels.sh — retire the `type:*` label axis to native GitHub Issue
# Types (Task/Bug/Feature, org-defined). For every medley issue carrying a `type:*`
# label the migration SETS the native issue type, then removes the label — in that
# order, and only removes the label once the type set is confirmed to have taken
# (the REST/`gh` API silently drops a type-set without push access, so an
# unconfirmed set must never strip the signalling label). This retires the type: label
# axis onto the org's native Issue Types, the locked issue-tracker taxonomy decision.
#
# Label -> native type mapping (colon-space and colon-no-space drift both handled):
#   bug  | fix                                        -> Bug
#   feature | feat                                     -> Feature
#   task | chore | docs | refactor | test | build | perf -> Task
#
# --dry-run is the DEFAULT and is strictly read-only: it emits the full proposed
# migration set (across ALL issue states — a closed issue still carrying a `type:*`
# label blocks the S10 label-definition prune) for owner review and mutates nothing.
# --apply performs the live migration and is a GATED, human-run post-merge step.
# --verify runs the post-migration sanity check (read-only).
#
# Idempotent: a re-run finds no `type:*`-labelled issue and is a no-op. Setting a
# type already equal to the target is skipped; removing an already-absent label is
# skipped. Label DEFINITIONS are intentionally NOT deleted here — the now-empty
# `type:*` labels are pruned at the S10 pulumi apply (github-iac is the sole label
# writer per EPIC #1491); this script only strips them off issues.
#
# set -e omitted: functions (mtl_issue_current_type, mtl_fetch_typed_issues, …)
# capture rc=$? after a command to branch on it — errexit is incompatible with
# that pattern. Safety comes from set -uo pipefail plus explicit rc checks.
set -uo pipefail

# Enumeration ceiling — beats gh's silent 30-row truncation AND covers the whole
# all-state backlog: medley carried ~859 all-state issues at authoring time (the
# type:* labels sit mostly on OLDER, closed issues), so a low ceiling would silently
# migrate only the recent window and let --verify falsely pass. Set well above the
# backlog; override with --limit for other repos.
DEFAULT_LIMIT=2000

readonly EX_OK=0 EX_USAGE=2 EX_PROVIDER=8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly GH_BOT="$SCRIPT_DIR/../../github-auth/gh-bot.sh"

# ===========================================================================
# Pure logic (no I/O) — unit-tested by migrate-type-labels.test.sh.
# ===========================================================================

# mtl_map_label_to_type <label> — echo the native issue type for a `type:*` label.
# Return: 0 = mapped (type echoed), 1 = not a `type:*` label at all,
#         2 = a `type:*` label with no mapping (unrecognized — never guessed).
mtl_map_label_to_type() {
  local label="$1" key
  case "$label" in
    type:*) key="${label#type:}" ;;
    *) return 1 ;;
  esac
  # Tolerate the colon-space drift form (`type: chore`) and stray surrounding space.
  key="${key#"${key%%[![:space:]]*}"}" # ltrim
  key="${key%"${key##*[![:space:]]}"}" # rtrim
  key="${key,,}"                       # lowercase (bash builtin — no fork in the hot loop)
  case "$key" in
    bug | fix) echo "Bug" ;;
    feature | feat) echo "Feature" ;;
    task | chore | docs | refactor | test | build | perf) echo "Task" ;;
    *) return 2 ;;
  esac
}

# mtl_targets_from_labels — read an issue's label names on stdin (one per line) and
# emit a single verdict line describing the type-axis migration for that issue:
#   TARGET <Type>          exactly one native type across all `type:*` labels — migrate
#   CONFLICT <T1,T2,...>   `type:*` labels disagree on the native type — review only
#   UNMAPPED <label,...>   a `type:*` label with no known mapping — review only
#   NONE                   no `type:*` label present
# CONFLICT/UNMAPPED are never auto-migrated (native types are single-select; a wrong
# guess is unrecoverable) — they surface for owner triage.
mtl_targets_from_labels() {
  local line type rc
  local -a targets=() unmapped=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    type="$(mtl_map_label_to_type "$line")"
    rc=$?
    case "$rc" in
      0) targets+=("$type") ;;
      1) ;; # not a type: label
      2) unmapped+=("$line") ;;
      *) ;; # mtl_map_label_to_type only returns 0|1|2
    esac
  done
  if ((${#unmapped[@]} > 0)); then
    local IFS=,
    printf 'UNMAPPED %s\n' "${unmapped[*]}"
    return 0
  fi
  if ((${#targets[@]} == 0)); then
    echo "NONE"
    return 0
  fi
  # Distinct targets, first-seen order — pure bash (this runs once per issue across
  # the whole backlog, so no per-issue sort/grep/paste fork on the common path).
  local t
  local -A seen=()
  local -a distinct=()
  for t in "${targets[@]}"; do
    [[ -n "${seen[$t]:-}" ]] && continue
    seen[$t]=1
    distinct+=("$t")
  done
  if ((${#distinct[@]} > 1)); then
    # Rare: labels disagree. Sort for a deterministic conflict list (fork tolerated).
    printf 'CONFLICT %s\n' "$(printf '%s\n' "${distinct[@]}" | sort | paste -sd, -)"
    return 0
  fi
  printf 'TARGET %s\n' "${distinct[0]}"
}

# mtl_type_labels_from_labels — read label names on stdin, echo only the `type:*`
# ones (the labels the apply path removes once the native type is confirmed set).
mtl_type_labels_from_labels() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      type:*) printf '%s\n' "$line" ;;
      *) ;;
    esac
  done
}

# mtl_absence_verdict <gh-exit-code> <label-names> <grep-pattern> — the fail-closed
# sanity discipline (mirrors S7): a provider/fetch failure must NEVER read as
# "clean". Prints the verdict and returns a distinct code:
#   rc != 0          -> "ERROR"   return 2  (fetch failed — check FAILS)
#   pattern present  -> "PRESENT" return 1  (label still there — check FAILS)
#   pattern absent   -> "ABSENT"  return 0  (the only clean signal)
mtl_absence_verdict() {
  local rc="$1" out="$2" pattern="$3"
  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR"
    return 2
  fi
  if grep -qE "$pattern" <<<"$out"; then
    echo "PRESENT"
    return 1
  fi
  echo "ABSENT"
  return 0
}

# ===========================================================================
# I/O helpers (gh) — writes route through the bot wrapper when present
# (docs/conventions/github-ops.md "Bot identity"); reads use bare gh.
# ===========================================================================

log() { printf '%s\n' "$*" >&2; }

gh_write() {
  if [[ -f "$GH_BOT" ]]; then
    bash "$GH_BOT" "$@"
  else
    gh "$@"
  fi
}

mtl_require_prereqs() {
  command -v gh >/dev/null 2>&1 || {
    log "prerequisite missing: gh (GitHub CLI)"
    exit "$EX_USAGE"
  }
  command -v jq >/dev/null 2>&1 || {
    log "prerequisite missing: jq"
    exit "$EX_USAGE"
  }
}

# mtl_fetch_typed_issues <repo> — JSON array of ALL-state issues that carry at least
# one `type:*` label, each with number/title/state/labels/issueType. A non-zero fetch
# aborts (a failed fetch is never an empty set — fail-closed). The abort's `exit`
# fires inside the caller's $( ) subshell, so every call site MUST `|| exit` to
# propagate it — without that, the failure reads as an empty set.
mtl_fetch_typed_issues() {
  local repo="$1" out rc
  out="$(gh issue list -R "$repo" --state all --limit "$LIMIT" \
    --json number,title,state,labels,issueType)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "fetch failed for $repo (exit $rc) — aborting (a failed fetch is never an empty set)"
    exit "$EX_PROVIDER"
  fi
  printf '%s\n' "$out" \
    | jq -c '[.[] | select(any(.labels[]?; .name | startswith("type:")))]'
}

# mtl_issue_current_type <repo> <number> — echo the issue's current native type name,
# or empty string when it has none. Returns non-zero on a fetch failure so the caller
# never treats a failed read as "no type". CR-stripped (gh emits CRLF on Windows; a
# trailing CR would defeat the target-equality guard in mtl_apply_one).
mtl_issue_current_type() {
  local repo="$1" number="$2" out rc name
  out="$(gh issue view "$number" -R "$repo" --json issueType)"
  rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  name="$(jq -r '.issueType.name // ""' <<<"$out")"
  printf '%s' "${name//$'\r'/}"
}

# ===========================================================================
# Migration planning (read-only) — one plan line per issue.
# ===========================================================================

# mtl_plan <repo> — emit a plan line per typed issue:
#   PLAN <number> SET <Type> CURRENT <cur|none> REMOVE <label|label,...>
#   HOLD <number> CONFLICT <T1,T2>       (labels disagree — review, untouched)
#   HOLD <number> UNMAPPED <label,...>   (unknown type: label — review, untouched)
# Aborts on a failed fetch (fail-closed; call sites consuming it in a $( ) subshell
# MUST `|| exit` — see mtl_fetch_typed_issues).
mtl_plan() {
  local repo="$1" issues rows number current labelblob labels verdict kind rest type_labels
  issues="$(mtl_fetch_typed_issues "$repo")" || exit
  # ONE jq pass over the whole backlog (a per-issue jq call would fork hundreds of
  # times). Each row is <number><RS><current-type><RS><label<US>label<US>...>, using
  # the ASCII record/unit separators (RS=U+001E, US=U+001F): NON-whitespace field
  # delimiters so `read` KEEPS the empty current-type field (a whitespace IFS like tab
  # collapses consecutive delimiters, so `current` would swallow the labels — every
  # medley issue is currently untyped, so that would zero the whole plan), and
  # separators that survive label names with spaces or commas. CR is stripped: jq/gh
  # emit CRLF on Windows, which would otherwise cling to the last field.
  rows="$(jq -r '.[] | [(.number | tostring), (.issueType.name // ""), ([.labels[].name] | join("\u001f"))] | join("\u001e")' <<<"$issues")"
  rows="${rows//$'\r'/}"
  while IFS=$'\x1e' read -r number current labelblob; do
    [[ -n "$number" ]] || continue
    labels="${labelblob//$'\x1f'/$'\n'}"
    verdict="$(printf '%s\n' "$labels" | mtl_targets_from_labels)"
    kind="${verdict%% *}"
    rest="${verdict#* }"
    case "$kind" in
      TARGET)
        [[ -n "$current" ]] || current="none"
        type_labels="$(printf '%s\n' "$labels" | mtl_type_labels_from_labels | paste -sd, -)"
        printf 'PLAN %s SET %s CURRENT %s REMOVE %s\n' "$number" "$rest" "$current" "$type_labels"
        ;;
      CONFLICT) printf 'HOLD %s CONFLICT %s\n' "$number" "$rest" ;;
      UNMAPPED) printf 'HOLD %s UNMAPPED %s\n' "$number" "$rest" ;;
      NONE) ;;                                            # filtered out upstream; defensive
      *) log "  #$number unexpected verdict: $verdict" ;; # mtl_targets_from_labels invariant
    esac
  done <<<"$rows"
}

# ===========================================================================
# Apply actions (gated) — set-then-remove, guarded on read-back for idempotency
# AND against a silently-dropped type-set.
# ===========================================================================

# mtl_apply_one <repo> <number> <target-type> <comma-labels> — set the native type
# (only if it differs), CONFIRM it took by re-reading, then remove the `type:*`
# labels only on confirmation. A dropped/failed set keeps the labels and reports.
mtl_apply_one() {
  local repo="$1" number="$2" target="$3" labels_csv="$4" current confirmed lbl
  current="$(mtl_issue_current_type "$repo" "$number")" || {
    log "  #$number type read failed — skip (never strip a label on an unconfirmed state)"
    return 0
  }
  if [[ "$current" != "$target" ]]; then
    gh_write issue edit "$number" -R "$repo" --type "$target" >/dev/null || true
  fi
  confirmed="$(mtl_issue_current_type "$repo" "$number")" || confirmed=""
  if [[ "$confirmed" != "$target" ]]; then
    log "  #$number type-set to '$target' NOT confirmed (got '${confirmed:-<read-failed>}') — keeping labels for review (push access?)"
    return 0
  fi
  [[ "$current" != "$target" ]] && log "  #$number type set -> $target"
  local -a present=()
  IFS=',' read -ra present <<<"$labels_csv"
  for lbl in "${present[@]}"; do
    [[ -n "$lbl" ]] || continue
    if gh_write issue edit "$number" -R "$repo" --remove-label "$lbl" >/dev/null 2>&1; then
      log "  #$number label '$lbl' removed"
    else
      log "  #$number label '$lbl' already absent — skip"
    fi
  done
}

# ===========================================================================
# Modes
# ===========================================================================

mtl_dry_run() {
  local repo="$1"
  log "== DRY RUN (read-only) — repo $repo, limit $LIMIT, state=ALL =="
  echo "# Proposed type-axis migration for $repo (review before --apply)"
  echo "# Enumerates ALL issue states — a closed issue still carrying a type:* label"
  echo "# would block the S10 label-definition prune, so it is migrated too."
  echo "# type:* label -> native issue type; PLAN lines migrate, HOLD lines need triage."
  mtl_plan "$repo"
  echo "# HOLD CONFLICT/UNMAPPED issues keep their labels (native types are single-select;"
  echo "# a wrong guess is unrecoverable). Label DEFINITIONS are pruned at S10, not here."
}

mtl_apply() {
  local repo="$1" plan line kind number verb target rest labels_csv
  log "== APPLY (LIVE MUTATION) — repo $repo, limit $LIMIT, state=ALL =="
  plan="$(mtl_plan "$repo")" || exit
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    kind="${line%% *}"
    case "$kind" in
      PLAN)
        # PLAN <number> SET <Type> CURRENT <cur> REMOVE <csv>
        read -r _ number _ target _ _ _ labels_csv <<<"$line"
        mtl_apply_one "$repo" "$number" "$target" "$labels_csv"
        ;;
      HOLD)
        read -r _ number verb rest <<<"$line"
        log "  #$number HELD ($verb $rest) — kept for owner triage, not migrated"
        ;;
      *) log "  unrecognized plan line: $line" ;;
    esac
  done <<<"$plan"
}

mtl_verify() {
  local repo="$1" issues rc names verdict fail=0
  log "== VERIFY (read-only) — repo $repo, limit $LIMIT, state=ALL =="
  issues="$(gh issue list -R "$repo" --state all --limit "$LIMIT" --json number,labels)"
  rc=$?
  # Key the verdict off label NAMES only — the raw JSON also carries label
  # DESCRIPTIONS, and one mentioning "type:" would otherwise false-trip the check.
  # Only project names on a clean fetch; a failed fetch stays ERROR (fail-closed).
  names=""
  [[ "$rc" -eq 0 ]] && names="$(jq -r '.[].labels[]?.name' <<<"$issues" 2>/dev/null)"
  verdict="$(mtl_absence_verdict "$rc" "$names" '^type:')" || true
  case "$verdict" in
    ABSENT) echo "OK   no issue carries a type:* label" ;;
    PRESENT)
      local remaining
      remaining="$(jq -r '[.[] | select(any(.labels[]?; .name | startswith("type:"))) | .number] | join(", ")' <<<"$issues")"
      echo "FAIL type:* label still on issue(s): $remaining"
      fail=1
      ;;
    ERROR)
      echo "FAIL issue fetch failed (exit $rc) — a failed fetch is never an empty set"
      fail=1
      ;;
    *)
      echo "FAIL unexpected verdict '$verdict'"
      fail=1
      ;;
  esac
  [[ "$fail" -eq 0 ]] || return 1
}

usage() {
  cat >&2 <<EOF
Usage: migrate-type-labels.sh [--dry-run|--apply|--verify] [--repo <owner>/<repo>] [--limit <n>]

  --dry-run   (DEFAULT) read-only; emit the proposed type-axis migration set for review
  --apply     GATED live migration (set native type, then remove the type:* label)
  --verify    read-only post-migration check (no issue carries a type:* label)

  --repo      target repo (default: current repo via gh)
  --limit     enumeration ceiling (default: $DEFAULT_LIMIT; beats gh's 30-row truncation)

Runbook + the gated post-merge steps: the S8 migration PR body / issue.
EOF
}

migrate_main() {
  local mode="dry-run" repo="" limit=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) mode="dry-run" ;;
      --apply) mode="apply" ;;
      --verify) mode="verify" ;;
      --repo)
        [[ $# -ge 2 ]] || {
          usage
          exit "$EX_USAGE"
        }
        repo="$2"
        shift
        ;;
      --limit)
        [[ $# -ge 2 ]] || {
          usage
          exit "$EX_USAGE"
        }
        limit="$2"
        shift
        ;;
      -h | --help)
        usage
        exit "$EX_OK"
        ;;
      *)
        usage
        exit "$EX_USAGE"
        ;;
    esac
    shift
  done

  LIMIT="${limit:-$DEFAULT_LIMIT}"
  [[ "$LIMIT" =~ ^[0-9]+$ ]] || {
    log "--limit must be a positive integer"
    exit "$EX_USAGE"
  }

  mtl_require_prereqs
  if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)" || {
      log "could not resolve current repo — pass --repo <owner>/<repo>"
      exit "$EX_USAGE"
    }
  fi

  case "$mode" in
    dry-run) mtl_dry_run "$repo" ;;
    apply) mtl_apply "$repo" ;;
    verify) mtl_verify "$repo" ;;
    *)
      usage
      exit "$EX_USAGE"
      ;;
  esac
}

# Entrypoint guard: run only when executed, not when sourced by the test.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  migrate_main "$@"
fi
