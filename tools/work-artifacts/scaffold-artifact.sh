#!/usr/bin/env bash
# Scaffold a .work/<slug>/ artifact from a templates/<type>.md skeleton.
#
# "Script the mechanical, keep judgment human": stubs the mechanical fields
# (journal ISO-basic timestamp, slug, session_id, chain frontmatter) and the
# fixed-name stage skeletons, leaving `<fill: …>` markers for the model; never
# judges status or chain membership. Slug defaults to the current branch
# (derive-slug.sh); --slug overrides it for multi-WIP-on-one-branch work.
#
# Supported types:
#   journal <journaltype> <topic>           always written, ISO-basic-timestamped
#   explore | research | plan | deviations  fixed-name at slice root, no-clobber
#
# Exit: 0 written or already-present | 1 not in a git repo / write failure | 2 usage error.

# No `set -e`: not-in-a-repo is an expected, explicitly-handled failure
# (matches derive-slug.sh / ensure-slice-manifest.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fixed-name stage artifacts: <type> → slice-root filename. These are living
# docs scaffolded once then hand-edited, so their dispatch is no-clobber.
declare -A FIXED_NAME_ARTIFACTS=(
  [explore]=EXPLORE.md
  [research]=RESEARCH.md
  [plan]=PLAN.md
  [deviations]=DEVIATIONS.md
)

usage() {
  cat <<'EOF'
scaffold-artifact.sh — stub a .work/<slug>/ artifact from a templates/<type>.md skeleton.

Usage:
  scaffold-artifact.sh journal <journaltype> <topic> [--slug <slug>]
  scaffold-artifact.sh <type> [--slug <slug>]
  scaffold-artifact.sh --help

  <journaltype>  handoff | decision | note | scope-change | attempt
  <type>         explore | research | plan | deviations
  --slug <slug>  override the branch-derived slug (multi-WIP on one branch)

journal writes .work/<slug>/journal/<ISO-basic>Z-<journaltype>-<topic>.md (always timestamped).
<type>  writes .work/<slug>/<CAPS>.md (no-clobber: prints existing path + exit 0 if present).
Prints the written (or already-present) artifact path.
Exit: 0 written or already-present | 1 not in a git repo / write failure | 2 usage error.
EOF
}

# --- arg parse: positionals + optional --slug ---
slug_override=""
positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --slug)
      slug_override="${2:-}"
      if [[ -z "$slug_override" ]]; then
        echo "scaffold-artifact: --slug requires a value" >&2
        exit 2
      fi
      # --slug names the slice directory AND is the lookup key every slug-derived
      # tool reuses (work-status.sh --phases, /handoff, /retro), so it must be a
      # single self-contained path segment. Reject path separators and '..': a
      # `--slug ../x` would resolve slice_dir below to "$target_root/.work/../x"
      # and escape .work/. Branch-derived slugs are already safe (derive-slug.sh
      # + git refname rules forbid '..'), so only the override needs this guard.
      if [[ "$slug_override" == */* || "$slug_override" == *\\* || "$slug_override" == *..* ]]; then
        echo "scaffold-artifact: --slug must be a single path segment (no '/', '\\', or '..'): $slug_override" >&2
        exit 2
      fi
      shift 2
      ;;
    -*)
      echo "scaffold-artifact: unknown option: $1" >&2
      exit 2
      ;;
    *)
      positionals+=("$1")
      shift
      ;;
  esac
done

artifact_type="${positionals[0]:-}"
if [[ -z "$artifact_type" ]]; then
  echo "scaffold-artifact: missing artifact type" >&2
  usage >&2
  exit 2
fi

# --- slug + repo root (shared by every type) ---
target_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$target_root" ]]; then
  echo "scaffold-artifact: not inside a git repository" >&2
  exit 1
fi
if [[ -n "$slug_override" ]]; then
  slug="$slug_override"
else
  slug="$(bash "$SCRIPT_DIR/derive-slug.sh")"
fi
slice_dir="$target_root/.work/$slug"
# shellcheck source=slice-history-dir.sh
source "$SCRIPT_DIR/slice-history-dir.sh"

# --- per-type: resolve template + output path, validate, set fill vars ---
template=""
out=""
clobber="" # "no" → skip write if the target already exists
case "$artifact_type" in
  journal)
    journaltype="${positionals[1]:-}"
    topic="${positionals[2]:-}"
    case "$journaltype" in
      handoff | decision | note | scope-change | attempt) ;;
      *)
        echo "scaffold-artifact: journal requires <journaltype> ∈ {handoff,decision,note,scope-change,attempt}" >&2
        exit 2
        ;;
    esac
    if [[ -z "$topic" ]]; then
      echo "scaffold-artifact: journal requires a <topic>" >&2
      exit 2
    fi
    # <topic> is a free-form positional (unlike the derive-slug-validated slug),
    # so normalize it to a safe kebab filename component before it lands in the
    # journal path: map every char outside [A-Za-z0-9-] to a dash (neutralizes
    # path separators, whitespace, and '..'), collapse dash runs, trim. Guards
    # the filename contract scaffold-artifact.test.sh locks + the slug-derived
    # tooling (/handoff, discover-session-chain.sh) walks.
    topic="${topic//[^A-Za-z0-9-]/-}"
    while [[ "$topic" == *--* ]]; do topic="${topic//--/-}"; done
    topic="${topic#-}"
    topic="${topic%-}"
    if [[ -z "$topic" ]]; then
      echo "scaffold-artifact: <topic> has no kebab-safe characters" >&2
      exit 2
    fi
    # One timestamp capture, two formats: the filename ISO-basic stamp and the
    # frontmatter ISO-extended `date:` must name the same instant, so derive the
    # extended form from the basic stamp by string-slice (two `date` calls could
    # straddle a second).
    TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    DATE="${TIMESTAMP:0:4}-${TIMESTAMP:4:2}-${TIMESTAMP:6:2}T${TIMESTAMP:9:2}:${TIMESTAMP:11:2}:${TIMESTAMP:13:2}Z"
    TYPE="$journaltype"
    TOPIC="$topic"
    SESSION_ID="${CLAUDE_CODE_SESSION_ID:-unknown}"
    export SLUG="$slug" DATE TIMESTAMP TYPE TOPIC SESSION_ID
    template="$SCRIPT_DIR/templates/journal.md"
    history_dir="$SLICE_HISTORY_DIR_BASENAME"
    out="$slice_dir/$history_dir/${TIMESTAMP}-${journaltype}-${topic}.md"
    ;;
  explore | research | plan | deviations)
    if [[ -n "${positionals[1]:-}" ]]; then
      echo "scaffold-artifact: '$artifact_type' takes no positional args (got '${positionals[1]}')" >&2
      exit 2
    fi
    # Fixed-name templates carry no ${VAR} placeholders — fill_template copies
    # them verbatim (and normalizes the trailing newline), so no exports needed.
    template="$SCRIPT_DIR/templates/${artifact_type}.md"
    out="$slice_dir/${FIXED_NAME_ARTIFACTS[$artifact_type]}"
    clobber="no"
    ;;
  *)
    echo "scaffold-artifact: unsupported artifact type '$artifact_type'" >&2
    echo "  supported: journal | explore | research | plan | deviations" >&2
    exit 2
    ;;
esac

# --- no-clobber for living docs: present → print + exit 0 (idempotent) ---
if [[ "$clobber" == "no" && -f "$out" ]]; then
  printf '%s\n' "$out"
  exit 0
fi

# --- shared tail: mkdir, fill, verify, print ---
if ! mkdir -p "${out%/*}"; then
  echo "scaffold-artifact: failed to create ${out%/*}" >&2
  exit 1
fi
# shellcheck source=lib/fill-template.sh
source "$SCRIPT_DIR/lib/fill-template.sh"
fill_template "$template" >"$out"
if [[ ! -s "$out" ]]; then
  echo "scaffold-artifact: failed to write $out" >&2
  exit 1
fi
printf '%s\n' "$out"
