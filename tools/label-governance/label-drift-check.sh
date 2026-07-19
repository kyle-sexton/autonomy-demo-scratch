#!/usr/bin/env bash
# label-drift-check.sh — report labels present LIVE on a repo but NOT in its
# declared set (undeclared drift), the audit that recurred through the
# governance research made runnable.
#
# The declared set is the github-iac authoritative label set for the repo
# (_core union ExtraLabels), produced by extract-declared-labels.sh from the
# github-iac SSOT — never snapshotted here (the definitions live only in
# github-iac; medley cites the live set, it does not copy members).
#
# Fail-closed discipline (the S7/S8/S9 trap): a label fetch that fails MUST exit
# with a data error, never a clean result — a provider/gh error read as "no
# drift" is exactly how drift silently recurs. Live labels are fetched with an
# explicit high --limit and filtered CLIENT-SIDE (gh --search/--label is fuzzy
# for colon-bearing values, so the whole set is pulled and diffed locally).
#
# Usage:
#   label-drift-check.sh --repo <owner/name> --declared <file>
#   label-drift-check.sh --repo <owner/name> --declared <file> --live <file>
#   label-drift-check.sh --repo <owner/name> --declared <file> --allowlist <file>
#
#   --live <file>       Read live label names from a file instead of gh (test
#                        seam / offline). One name per line.
#   --limit <n>          gh label list page size (default 9999, well above any
#                        backlog).
#   --allowlist <file>  Glob patterns (one per line, '#'-comments allowed) for
#                        undeclared labels that are known and tracked pending a
#                        github-iac PR -- still reported, but do not fail the
#                        check on their own. A pattern like 'ecosystem: *'
#                        allowlists that whole axis.
#
# Exit: 0 no drift · 1 blocking (unallowlisted) undeclared labels found ·
#       2 usage · 3 fetch/data error ·
#       4 undeclared labels found, but every one matched the allowlist (still
#         reported for visibility, does not fail the check).
set -euo pipefail

REPO=""
DECLARED_FILE=""
LIVE_FILE=""
ALLOWLIST_FILE=""
LIMIT=9999

usage() {
  cat <<'EOF'
label-drift-check.sh — report labels present live on a repo but not in its
declared set (undeclared drift). Fail-closed: a fetch failure is a data error,
never a clean result.

Usage:
  label-drift-check.sh --repo <owner/name> --declared <file> [--live <file>] [--allowlist <file>] [--limit <n>]

  --repo       owner/name of the repo to check.
  --declared   File of declared label names (one per line), from the extractor.
  --live       Read live names from a file instead of gh (test seam / offline).
  --allowlist  Glob patterns (one per line) for undeclared labels that are
               tracked pending a github-iac PR -- reported, but do not fail
               the check on their own.
  --limit      gh label list page size (default 9999, well above any backlog).

Exit: 0 no drift · 1 blocking (unallowlisted) undeclared labels · 2 usage ·
      3 fetch/data error · 4 undeclared labels found, all allowlisted.
EOF
}

die_usage() {
  echo "label-drift-check.sh: $1" >&2
  echo "Usage: label-drift-check.sh --repo <owner/name> --declared <file> [--live <file>] [--allowlist <file>] [--limit <n>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --declared)
      DECLARED_FILE="${2:-}"
      shift 2
      ;;
    --live)
      LIVE_FILE="${2:-}"
      shift 2
      ;;
    --allowlist)
      ALLOWLIST_FILE="${2:-}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

if [[ -n "$ALLOWLIST_FILE" ]]; then
  [[ -f "$ALLOWLIST_FILE" ]] || die_usage "--allowlist file not found: $ALLOWLIST_FILE"
fi

[[ -n "$REPO" ]] || die_usage "--repo is required"
[[ -n "$DECLARED_FILE" ]] || die_usage "--declared is required"
[[ -f "$DECLARED_FILE" ]] || die_usage "--declared file not found: $DECLARED_FILE"

# A declared set that is empty is treated as an ERROR, not "everything drifts":
# an empty declared file means the extractor failed (SSOT shape changed), and
# fail-closed means we refuse to guess rather than report the whole repo as drift.
declared=$(grep -v '^[[:space:]]*$' "$DECLARED_FILE" | tr -d '\r' | sort -u || true)
if [[ -z "$declared" ]]; then
  echo "::error::label-drift-check: declared set for $REPO is empty — extractor likely failed. Refusing to report drift against an empty baseline (fail-closed)." >&2
  exit 3
fi

# Fetch live labels. Separate a fetch FAILURE (gh non-zero) from an empty-but-OK
# result: only a non-zero exit is an error. gh exit is captured explicitly so a
# transient/auth failure can never be misread as "no labels, therefore clean".
if [[ -n "$LIVE_FILE" ]]; then
  [[ -f "$LIVE_FILE" ]] || die_usage "--live file not found: $LIVE_FILE"
  live_raw=$(cat "$LIVE_FILE")
else
  gh_err=$(mktemp)
  trap 'rm -f "$gh_err"' EXIT
  set +e
  live_raw=$(gh label list --repo "$REPO" --limit "$LIMIT" --json name --jq '.[].name' 2>"$gh_err")
  gh_rc=$?
  set -e
  if [[ "$gh_rc" -ne 0 ]]; then
    echo "::error::label-drift-check: gh label list failed for $REPO (exit $gh_rc) — treating as a data error, NOT as 'no drift'." >&2
    sed 's/^/  gh: /' "$gh_err" >&2 2>/dev/null || true
    exit 3
  fi
fi

live=$(printf '%s\n' "$live_raw" | grep -v '^[[:space:]]*$' | tr -d '\r' | sort -u || true)

# Undeclared = live names that exactly (whole-line, literal) match no declared
# name. -F literal + -x whole-line so a name that is a substring of another
# ("area: ci" vs "area: ci-cd") is never a false match.
undeclared=$(printf '%s\n' "$live" | grep -Fxv -f <(printf '%s\n' "$declared") || true)

if [[ -z "$undeclared" ]]; then
  echo "OK: $REPO has no undeclared labels (all live labels are in the declared set)."
  exit 0
fi

count=$(printf '%s\n' "$undeclared" | grep -c . || true)
echo "DRIFT: $REPO has $count undeclared label(s) not in the github-iac declared set:" >&2
printf '%s\n' "$undeclared" | sed 's/^/  - /' >&2

if [[ -z "$ALLOWLIST_FILE" ]]; then
  exit 1
fi

# A pattern file line is either literal or contains '*'; bash [[ == ]] handles
# both without a separate literal/glob branch. Comments and blanks are dropped.
mapfile -t allow_patterns < <(grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | grep -v '^[[:space:]]*$' | tr -d '\r')

blocking=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  matched=0
  for pattern in "${allow_patterns[@]}"; do
    # shellcheck disable=SC2053  # unquoted RHS is intentional: enables glob matching
    if [[ "$name" == $pattern ]]; then
      matched=1
      break
    fi
  done
  if [[ "$matched" -eq 0 ]]; then
    blocking+="$name"$'\n'
  fi
done <<<"$undeclared"

if [[ -z "$blocking" ]]; then
  echo "All $count undeclared label(s) for $REPO matched the allowlist ($ALLOWLIST_FILE) -- tracked, not blocking." >&2
  exit 4
fi

blocking_count=$(printf '%s' "$blocking" | grep -c . || true)
# Names, not re-printed with the "  - " marker used above: the caller workflow
# greps that exact marker to build its drift report, and every name here was
# already printed once in the full undeclared list -- re-marking them would
# double them up in that report.
echo "BLOCKING: $blocking_count of $REPO's $count undeclared label(s) are NOT on the allowlist: $(printf '%s' "$blocking" | tr '\n' ',' | sed 's/,$//')" >&2
exit 1
