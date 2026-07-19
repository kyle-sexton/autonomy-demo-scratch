#!/usr/bin/env bash
# rename-drift-labels.sh — clean the remaining medley label drift by RENAMING the
# drifted label definitions to their canonical colon-space names (EPIC #1491's locked
# taxonomy). Renames go out-of-band via the GitHub REST label PATCH, which PRESERVES
# every issue/PR association (a rename is not a delete-and-recreate) — so the S10
# pulumi apply, whose ExtraLabels (S1 #1492) declare the new names, becomes a no-op
# adopt rather than a prune-and-add that would strip associations.
#
# Rename map (drifted -> canonical). SINGLE SOURCE OF TRUTH: RDL_RENAMES below.
#   category:guardrails  -> area: guardrails      (category: is not a declared axis)
#   area:claude-code     -> area: claude-code     (colon-space normalize)
#   area:ci-cd           -> area: ci-cd           (colon-space normalize)
#   wayfind:{research,interview,design,prototype,task} -> wayfind: <t>  (colon-space)
#
# --dry-run is the DEFAULT and is strictly read-only: it emits the proposed rename set
# with the LIVE association count per label (counted CLIENT-SIDE — never gh's fuzzy
# server-side `--label`/search filter, which collides with the `type:`/`area:` search
# qualifiers and grossly over-counts colon-containing names) for owner review, and
# mutates nothing. --apply performs the live renames and is a GATED, human-run
# post-merge step. --verify runs the post-rename sanity check (read-only).
#
# Idempotent: a re-run whose drifted source label is already gone (renamed) skips it.
# Label DEFINITIONS for the retired cruft (`javascript`, `category:general`) are NOT
# deleted here — github-iac is the sole label writer (EPIC #1491); the now-undeclared
# labels are pruned at the S10 pulumi apply. They are surfaced in --dry-run (with live
# use counts) so the owner sees what that prune drops.
set -uo pipefail

# Enumeration ceiling — beats gh's silent 30-row truncation AND covers the whole
# all-state backlog (issues AND PRs both carry labels): medley had ~859 issues + ~643
# PRs at authoring time, so a low ceiling would silently count only a recent window
# and under-report associations. Set well above both; override with --limit. The one
# ceiling governs every enumeration: label definitions, issues, and PRs.
DEFAULT_LIMIT=3000

readonly EX_OK=0 EX_USAGE=2 EX_PROVIDER=8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly GH_BOT="$SCRIPT_DIR/../../github-auth/gh-bot.sh"

# The closed, reviewed rename set — "drifted-name|canonical-name" pairs. Source names
# are the current (drifted) colon-no-space forms; targets are the canonical colon-space
# forms S1's ExtraLabels declare. Enumerated (not pattern-derived) so the set stays an
# auditable allowlist — a stray drift form is never guessed at.
readonly RDL_RENAMES=(
  "category:guardrails|area: guardrails"
  "area:claude-code|area: claude-code"
  "area:ci-cd|area: ci-cd"
  "wayfind:research|wayfind: research"
  "wayfind:interview|wayfind: interview"
  "wayfind:design|wayfind: design"
  "wayfind:prototype|wayfind: prototype"
  "wayfind:task|wayfind: task"
)

# Retired cruft this slice does NOT rename or delete — reported in --dry-run for owner
# review, then pruned at the S10 apply once undeclared. `category:general` is an
# undeclared `category:` label the EPIC never assigned a landing (its fate is the
# bundled "retire the category: axis" owner decision in the PR); `javascript` is the
# EPIC-decided prune.
readonly RDL_UNDECLARED=(
  "javascript"
  "category:general"
)

# ===========================================================================
# Pure logic (no I/O) — unit-tested by rename-drift-labels.test.sh.
# ===========================================================================

# rdl_target_for_label <drifted-name> — echo the canonical rename target for a drifted
# label. Return: 0 = in the rename set (target echoed); 1 = not a rename source.
rdl_target_for_label() {
  local name="$1" pair
  for pair in "${RDL_RENAMES[@]}"; do
    if [[ "${pair%%|*}" == "$name" ]]; then
      printf '%s\n' "${pair#*|}"
      return 0
    fi
  done
  return 1
}

# rdl_absence_verdict <gh-exit-code> <names> <grep-pattern> — the fail-closed sanity
# discipline (mirrors the sibling migrations): a provider/fetch failure must NEVER read
# as "clean". Prints the verdict and returns a distinct code:
#   rc != 0          -> "ERROR"   return 2  (fetch failed — check FAILS)
#   pattern present  -> "PRESENT" return 1  (drift still there — check FAILS)
#   pattern absent   -> "ABSENT"  return 0  (the only clean signal)
rdl_absence_verdict() {
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

rdl_require_prereqs() {
  command -v gh >/dev/null 2>&1 || {
    log "prerequisite missing: gh (GitHub CLI)"
    exit "$EX_USAGE"
  }
  command -v jq >/dev/null 2>&1 || {
    log "prerequisite missing: jq"
    exit "$EX_USAGE"
  }
}

# rdl_fetch_label_names <repo> — newline-separated list of the repo's label NAMES.
# A non-zero fetch aborts (a failed fetch is never an empty set — fail-closed). The
# abort's `exit` fires inside the caller's $( ) subshell, so every call site MUST
# `|| exit` to propagate it — without that, the failure reads as an empty set.
rdl_fetch_label_names() {
  local repo="$1" out rc
  out="$(gh label list -R "$repo" --limit "$LIMIT" --json name)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "label fetch failed for $repo (exit $rc) — aborting (a failed fetch is never an empty set)"
    exit "$EX_PROVIDER"
  fi
  # Strip CR: on Windows Git Bash, gh's JSON through external jq -r carries a trailing
  # \r per name, which would defeat the exact grep -qxF match in rdl_name_present and
  # the anchored ^name$ match in rdl_verify (the latter fails OPEN — a still-present
  # drift label reads as ABSENT).
  jq -r '.[].name' <<<"$out" | tr -d '\r'
}

# rdl_fetch_items <repo> — JSON array of {number,labels} across ALL-state issues AND
# PRs (labels live on both; gh issue list excludes PRs, so both are fetched and merged).
# A non-zero fetch of either aborts (fail-closed; call sites MUST `|| exit` — see
# rdl_fetch_label_names).
rdl_fetch_items() {
  local repo="$1" issues prs rc
  issues="$(gh issue list -R "$repo" --state all --limit "$LIMIT" --json number,labels)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "issue fetch failed for $repo (exit $rc) — aborting (a failed fetch is never an empty set)"
    exit "$EX_PROVIDER"
  fi
  prs="$(gh pr list -R "$repo" --state all --limit "$LIMIT" --json number,labels)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "PR fetch failed for $repo (exit $rc) — aborting (a failed fetch is never an empty set)"
    exit "$EX_PROVIDER"
  fi
  printf '%s\n%s\n' "$issues" "$prs" | jq -s 'add'
}

# rdl_count_uses <items-json> <label-name> — exact CLIENT-SIDE count of items carrying
# the label. Never the fuzzy server-side `--label`/search filter.
rdl_count_uses() {
  jq --arg L "$2" '[.[] | select(any(.labels[]?; .name == $L))] | length' <<<"$1"
}

# rdl_name_present <newline-names> <name> — 0 if an exact label name is in the list.
rdl_name_present() {
  grep -qxF "$2" <<<"$1"
}

# ===========================================================================
# Modes
# ===========================================================================

rdl_dry_run() {
  local repo="$1" names items pair old new uses lbl
  log "== DRY RUN (read-only) — repo $repo, limit $LIMIT, state=ALL (issues+PRs) =="
  names="$(rdl_fetch_label_names "$repo")" || exit
  items="$(rdl_fetch_items "$repo")" || exit
  echo "# Proposed label-drift renames for $repo (review before --apply)."
  echo "# Counts are LIVE associations counted CLIENT-SIDE (issues+PRs) — NOT gh's"
  echo "# fuzzy server-side --label/search filter (which over-counts colon names)."
  echo "# A rename PRESERVES every association; the count is informational for review."
  for pair in "${RDL_RENAMES[@]}"; do
    old="${pair%%|*}"
    new="${pair#*|}"
    if rdl_name_present "$names" "$old"; then
      uses="$(rdl_count_uses "$items" "$old")"
      printf 'RENAME %-22s -> %-22s (%s live associations, preserved)\n' "$old" "$new" "$uses"
    elif rdl_name_present "$names" "$new"; then
      printf 'DONE   %-22s already renamed to %s\n' "$old" "$new"
    else
      printf 'SKIP   %-22s absent (nothing to rename)\n' "$old"
    fi
  done
  echo "# Retired cruft — NOT renamed/deleted here; pruned at the S10 apply once"
  echo "# undeclared. category:general has NO EPIC-assigned landing (owner decision)."
  for lbl in "${RDL_UNDECLARED[@]}"; do
    if rdl_name_present "$names" "$lbl"; then
      uses="$(rdl_count_uses "$items" "$lbl")"
      printf 'UNDECLARED %-18s (%s live associations — dropped when pruned at S10)\n' "$lbl" "$uses"
    else
      printf 'UNDECLARED %-18s absent\n' "$lbl"
    fi
  done
}

rdl_apply() {
  local repo="$1" names pair old new applied=0 skipped=0 failed=0
  log "== APPLY (LIVE MUTATION) — repo $repo =="
  names="$(rdl_fetch_label_names "$repo")" || exit
  for pair in "${RDL_RENAMES[@]}"; do
    old="${pair%%|*}"
    new="${pair#*|}"
    if ! rdl_name_present "$names" "$old"; then
      log "  '$old' absent — skip (already renamed or never existed)"
      skipped=$((skipped + 1))
      continue
    fi
    if gh_write api --method PATCH "repos/$repo/labels/$old" -f "new_name=$new" >/dev/null; then
      log "  '$old' -> '$new' (associations preserved)"
      applied=$((applied + 1))
    else
      log "  '$old' -> '$new' FAILED (does the target name already exist, or no write access?)"
      failed=$((failed + 1))
    fi
  done
  log "Apply summary: $applied renamed, $skipped skipped, $failed failed (of ${#RDL_RENAMES[@]})."
  log "Retired cruft (${RDL_UNDECLARED[*]}) left undeclared — pruned at the S10 apply, not here."
  # Fail the run when any rename failed — a partial apply must not read as success to a
  # runbook or chained command gating the S10 prune on this exit status.
  [[ "$failed" -eq 0 ]] || return 1
}

rdl_verify() {
  local repo="$1" names pair old new fail=0 verdict
  log "== VERIFY (read-only) — repo $repo =="
  names="$(rdl_fetch_label_names "$repo")" || exit
  for pair in "${RDL_RENAMES[@]}"; do
    old="${pair%%|*}"
    new="${pair#*|}"
    # Fail-closed absence check on the drifted source name (exact, anchored line match).
    verdict="$(rdl_absence_verdict 0 "$names" "^$(sed 's/[][\.*^$/]/\\&/g' <<<"$old")\$")"
    if [[ "$verdict" == "PRESENT" ]]; then
      echo "FAIL drifted label still present: '$old'"
      fail=1
    elif rdl_name_present "$names" "$new"; then
      echo "OK   '$old' -> '$new'"
    else
      echo "WARN '$old' gone but canonical '$new' not found (declared by S1 ExtraLabels at S10)"
    fi
  done
  [[ "$fail" -eq 0 ]] || return 1
}

usage() {
  cat >&2 <<EOF
Usage: rename-drift-labels.sh [--dry-run|--apply|--verify] [--repo <owner>/<repo>] [--limit <n>]

  --dry-run   (DEFAULT) read-only; emit the proposed rename set + live use counts
  --apply     GATED live rename (gh api PATCH new_name — preserves associations)
  --verify    read-only post-rename check (drifted names gone, canonical names present)

  --repo      target repo (default: current repo via gh)
  --limit     enumeration ceiling — labels, issues, AND PRs (default: $DEFAULT_LIMIT)

Runbook + the gated post-merge steps: the S9 PR body / issue #1499.
EOF
}

rename_main() {
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

  rdl_require_prereqs
  if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)" || {
      log "could not resolve current repo — pass --repo <owner>/<repo>"
      exit "$EX_USAGE"
    }
  fi

  case "$mode" in
    dry-run) rdl_dry_run "$repo" ;;
    apply) rdl_apply "$repo" ;;
    verify) rdl_verify "$repo" ;;
    *)
      usage
      exit "$EX_USAGE"
      ;;
  esac
}

# Entrypoint guard: run only when executed, not when sourced by the test.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rename_main "$@"
fi
