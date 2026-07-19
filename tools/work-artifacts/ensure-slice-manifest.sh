#!/usr/bin/env bash
# Ensure a slice manifest (README.md) exists for the current branch's .work/<slug>/.
#
# Idempotent: no-op when README.md already exists. Slice-creating skills
# (/explore, /research, /prd, /interview, /architect) call this so the
# always-first manifest is auto-stubbed. README frontmatter is the machine SSOT
# (status/created/updated, optional priority/issue/pr) per
# `.claude/rules/work-artifacts/manifest.md`.
#
# Slug derives from the current git branch via the sibling derive-slug.sh, run in
# the CWD; the slice lives under the CWD repo's git toplevel. That split (sibling
# script, CWD target) makes the script testable against a throwaway repo without
# copying tooling in. --slug overrides the branch-derived slug for
# multi-WIP-on-one-branch work.
#
# Usage:
#   ensure-slice-manifest.sh                 Create the manifest if missing; print its path.
#   ensure-slice-manifest.sh --slug <slug>   Create under .work/<slug>/ instead of the branch slug.
#   ensure-slice-manifest.sh --help          Show this help.
# Exit: 0 created-or-exists | 1 not inside a git repo | 2 usage error.

# No `set -e`: the not-in-a-repo path is an expected, explicitly-handled failure
# (matches derive-slug.sh / list-slug-artifacts.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
ensure-slice-manifest.sh — stub .work/<slug>/README.md for the current branch if absent.

Idempotent: no-op when the manifest already exists. Slug derives from the current
git branch (derive-slug.sh); --slug overrides it. Prints the manifest path on success.

Usage:
  ensure-slice-manifest.sh                 Create the manifest if missing.
  ensure-slice-manifest.sh --slug <slug>   Use <slug> instead of the branch-derived slug.
  ensure-slice-manifest.sh --help          Show this help.

Exit codes:
  0  manifest exists or was created
  1  not inside a git repository
  2  usage error
EOF
}

# Parse args: optional --slug override. This tool takes NO positionals, so any
# bare positional (or unknown option) is a usage error (exit 2) — unlike the
# sibling scaffold-artifact.sh, whose parser collects positionals.
slug_override=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --slug)
      slug_override="${2:-}"
      if [[ -z "$slug_override" ]]; then
        echo "ensure-slice-manifest: --slug requires a value" >&2
        exit 2
      fi
      # --slug names the slice directory AND is the lookup key every slug-derived
      # tool reuses (work-status.sh --phases, /handoff, /retro), so it must be a
      # single self-contained path segment. Reject path separators and '..': a
      # `--slug ../x` would resolve slice_dir below to "$target_root/.work/../x"
      # and escape .work/. Branch-derived slugs are already safe (derive-slug.sh
      # + git refname rules forbid '..'), so only the override needs this guard.
      if [[ "$slug_override" == */* || "$slug_override" == *\\* || "$slug_override" == *..* ]]; then
        echo "ensure-slice-manifest: --slug must be a single path segment (no '/', '\\', or '..'): $slug_override" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

target_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$target_root" ]]; then
  echo "ensure-slice-manifest: not inside a git repository" >&2
  exit 1
fi

if [[ -n "$slug_override" ]]; then
  slug="$slug_override"
else
  slug="$(bash "$SCRIPT_DIR/derive-slug.sh")"
fi
slice_dir="$target_root/.work/$slug"
manifest="$slice_dir/README.md"

if [[ -f "$manifest" ]]; then
  printf '%s\n' "$manifest"
  exit 0
fi

# ISO 8601 extended UTC (YYYY-MM-DDTHH:MM:SSZ) — matches the journal `date:`
# convention; `-u` forces UTC. work-status.sh sorts `updated` lexically, and
# ISO 8601 sorts lexically = chronologically.
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! mkdir -p "$slice_dir"; then
  echo "ensure-slice-manifest: failed to create $slice_dir" >&2
  exit 1
fi

# Human-readable Title Case H1 from the slug (hyphens->spaces, capitalize each
# word). The slug still names the directory + drives all tooling; only this
# display heading is prose. Acronym casing (API/UI/BFF/...) is a later human pass.
slug_title=""
# `read -ra` into an array (split on whitespace, NO glob expansion) — an
# unquoted `for _word in ${slug//-/ }` would pathname-expand a `--slug` override
# containing glob metachars (* ? [) against the CWD, corrupting the H1.
read -ra _words <<<"${slug//-/ }"
for _word in "${_words[@]}"; do
  slug_title+="${_word^} "
done
SLUG_TITLE="${slug_title% }"

# Fill the readme skeleton through the shared engine. Output is byte-for-byte
# identical to the former inline heredoc: the template carries the same static
# text + ${SLUG_TITLE}/${DATE} placeholders, and fill_template restores exactly
# one trailing newline.
export SLUG_TITLE DATE
# shellcheck source=lib/fill-template.sh
source "$SCRIPT_DIR/lib/fill-template.sh"
fill_template "$SCRIPT_DIR/templates/readme.md" >"$manifest"

if [[ ! -s "$manifest" ]]; then
  echo "ensure-slice-manifest: failed to write $manifest" >&2
  exit 1
fi

printf '%s\n' "$manifest"
exit 0
