#!/usr/bin/env bash
# Scaffold .work/<slug>/ agent-loop harness from examples/slice-harness templates.
#
# "Script the mechanical, keep judgment human" — fixed names + placeholders only.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE_ROOT="$SCRIPT_DIR/../examples/slice-harness"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

usage() {
  cat <<'EOF'
Usage: scaffold-slice-harness.sh --slug <slug> --phases <N> [--out-subdir <path>] [--force]

Creates .work/<slug>/scripts/ and research/ harness files from canonical templates.
No-clobber by default; --force overwrites scaffolded shells only (not filled prompts).

Examples:
  bash tools/agent-loop/scripts/scaffold-slice-harness.sh --slug youtube-skill --phases 7
EOF
}

SLUG=""
PHASE_MAX=""
OUT_SUBDIR=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)
      SLUG="${2:-}"
      shift 2
      ;;
    --phases)
      PHASE_MAX="${2:-}"
      shift 2
      ;;
    --out-subdir)
      OUT_SUBDIR="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SLUG" || -z "$PHASE_MAX" ]]; then
  echo "error: --slug and --phases are required" >&2
  usage >&2
  exit 2
fi

if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "error: --slug must match ^[a-z0-9][a-z0-9-]*$ (got: $SLUG)" >&2
  exit 2
fi

if [[ -z "$OUT_SUBDIR" ]]; then
  OUT_SUBDIR=".work/${SLUG}/out"
fi

if [[ "$OUT_SUBDIR" == /* || "$OUT_SUBDIR" == *".."* ]]; then
  echo "error: --out-subdir must be repo-relative without .. (got: $OUT_SUBDIR)" >&2
  exit 2
fi

SLICE_ROOT="$REPO_ROOT/.work/$SLUG"
mkdir -p "$SLICE_ROOT/scripts" "$SLICE_ROOT/research" "$REPO_ROOT/$OUT_SUBDIR"

substitute() {
  local content="$1"
  content="${content//\{\{SLUG\}\}/$SLUG}"
  content="${content//\{\{OUT_SUBDIR\}\}/$OUT_SUBDIR}"
  content="${content//\{\{PHASE_MAX\}\}/$PHASE_MAX}"
  content="${content//\{\{DEFAULT_MAX_ITER\}\}/20}"
  printf '%s' "$content"
}

write_file() {
  local dest="$1"
  local src="$2"
  if [[ -f "$dest" && "$FORCE" != true ]]; then
    echo "skip (exists): $dest"
    return 0
  fi
  substitute "$(cat "$src")" >"$dest"
  echo "wrote: $dest"
}

write_file "$SLICE_ROOT/research/implement-shared-rules.prompt.md" \
  "$TEMPLATE_ROOT/implement-shared-rules.prompt.md"

if [[ ! -f "$SLICE_ROOT/research/agent-loop-pilot-audit.md" || "$FORCE" == true ]]; then
  write_file "$SLICE_ROOT/research/agent-loop-pilot-audit.md" \
    "$TEMPLATE_ROOT/agent-loop-pilot-audit.md"
fi

write_file "$SLICE_ROOT/scripts/verify-common.sh" "$TEMPLATE_ROOT/verify-common.sh"
chmod +x "$SLICE_ROOT/scripts/verify-common.sh"

write_file "$SLICE_ROOT/scripts/run-phase.sh" "$TEMPLATE_ROOT/run-phase.sh.template"
chmod +x "$SLICE_ROOT/scripts/run-phase.sh"

for ((phase = 1; phase <= PHASE_MAX; phase++)); do
  prompt_dest="$SLICE_ROOT/research/implement-phase-${phase}.prompt.md"
  verify_dest="$SLICE_ROOT/scripts/verify-phase-${phase}.sh"
  if [[ -f "$prompt_dest" && "$FORCE" != true ]]; then
    echo "skip (exists): $prompt_dest"
  else
    content=$(substitute "$(cat "$TEMPLATE_ROOT/implement-phase.prompt.template.md")")
    content="${content//\{\{PHASE\}\}/$phase}"
    printf '%s' "$content" >"$prompt_dest"
    echo "wrote: $prompt_dest"
  fi
  if [[ -f "$verify_dest" && "$FORCE" != true ]]; then
    echo "skip (exists): $verify_dest"
  else
    content=$(substitute "$(cat "$TEMPLATE_ROOT/verify-phase.sh.template")")
    content="${content//\{\{PHASE\}\}/$phase}"
    printf '%s' "$content" >"$verify_dest"
    chmod +x "$verify_dest"
    echo "wrote: $verify_dest"
  fi
done

echo "slice harness ready: $SLICE_ROOT"
