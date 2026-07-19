#!/usr/bin/env bash
# list-managed-repos.sh — emit `<owner>/<repo>` for every label-managed repo in
# a github-iac program, derived at runtime from GovernedRepositories.cs. A repo
# is managed unless its spec carries `ManagedLabels: false` (the default is
# true — GovernedRepositorySpec.ManagedLabels = true).
#
# This is the "both accounts" enumeration the drift-check iterates: run once per
# github-iac checkout with that program's owner. Enumerating from the SSOT (not
# a list hardcoded in medley) keeps the managed-repo membership owned by
# github-iac, consistent with extract-declared-labels.sh.
#
# Usage:
#   list-managed-repos.sh --iac-dir <github-iac-checkout> --owner <owner>
#
# Exit: 0 ok · 2 usage · 3 parse error (no specs found — SSOT shape changed).
set -euo pipefail

IAC_DIR=""
OWNER=""

usage() {
  cat <<'EOF'
list-managed-repos.sh — emit <owner>/<repo> for every label-managed repo in a
github-iac program (managed unless the spec sets ManagedLabels: false).

Usage:
  list-managed-repos.sh --iac-dir <github-iac-checkout> --owner <owner>

Exit: 0 ok · 2 usage · 3 parse error (no specs found).
EOF
}

die_usage() {
  echo "list-managed-repos.sh: $1" >&2
  echo "Usage: list-managed-repos.sh --iac-dir <github-iac-checkout> --owner <owner>" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iac-dir)
      IAC_DIR="${2:-}"
      shift 2
      ;;
    --owner)
      OWNER="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$IAC_DIR" ]] || die_usage "--iac-dir is required"
[[ -n "$OWNER" ]] || die_usage "--owner is required"
REPOS_CS="$IAC_DIR/GovernedRepositories.cs"
[[ -f "$REPOS_CS" ]] || die_usage "GovernedRepositories.cs not found under --iac-dir: $REPOS_CS"

# Walk spec blocks. A block opens at `new("<name>"` and runs until the next
# `new("` (or EOF). Within a block, `ManagedLabels: false` opts the repo out;
# absence means managed (the C# default). Archived repos set ManagedLabels:false
# so they fall out naturally.
managed=$(awk -v owner="$OWNER" '
  match($0, /new\("[^"]+"/) {
    if (have && !optout) print owner "/" name
    name = substr($0, RSTART + 5, RLENGTH - 6)
    have = 1
    optout = 0
  }
  /ManagedLabels[[:space:]]*:[[:space:]]*false/ { optout = 1 }
  END { if (have && !optout) print owner "/" name }
' "$REPOS_CS")

if [[ -z "$managed" ]]; then
  echo "::error::list-managed-repos: no repo specs found in $REPOS_CS — SSOT shape changed (fail-closed)." >&2
  exit 3
fi

printf '%s\n' "$managed" | sort -u
