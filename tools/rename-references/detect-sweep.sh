#!/usr/bin/env bash
# Read-only rename sweep facts for /rename-references.
#
# Output: Mode, tokens, Pattern/Match lines, summary counts.
# Exit: always 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pattern-expand.sh
source "$SCRIPT_DIR/lib/pattern-expand.sh"

REGISTRY="$SCRIPT_DIR/patterns.registry.tsv"
MODE="blast"
OLD_TOKEN=""
NEW_TOKEN=""

usage() {
  cat <<'EOF'
detect-sweep.sh — emit rename reference match facts.

Usage:
  detect-sweep.sh --old <token> [--new <token>] --mode blast|half-rename|orphans
  detect-sweep.sh --help

Exit: always 0.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --old)
      OLD_TOKEN="${2:-}"
      shift 2
      ;;
    --new)
      NEW_TOKEN="${2:-}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "detect-sweep.sh: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  blast | half-rename | orphans) ;;
  *)
    echo "detect-sweep.sh: invalid --mode '$MODE'" >&2
    exit 2
    ;;
esac

if [[ -z "$OLD_TOKEN" ]]; then
  echo "detect-sweep.sh: --old is required" >&2
  exit 2
fi

if [[ "$MODE" != "blast" && -z "$NEW_TOKEN" ]]; then
  echo "detect-sweep.sh: --new is required for mode $MODE" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$repo_root" ]]; then
  printf 'Mode: %s\n' "$MODE"
  printf 'Error: not a git repository\n'
  exit 0
fi
cd "$repo_root" || exit 0

printf 'Mode: %s\n' "$MODE"
printf 'Old token: %s\n' "$OLD_TOKEN"
printf 'New token: %s\n' "${NEW_TOKEN:-n/a}"

declare -A file_hits=()
declare -A old_files=()
declare -A new_files=()
total_matches=0
orphan_broken=0
stale_functional=0

trim_excerpt() {
  local line="$1"
  line="${line//$'\r'/}"
  if ((${#line} > 100)); then
    line="${line:0:97}..."
  fi
  printf '%s' "$line"
}

readonly GREP_PATHS=(
  .claude .codex .cursor docs tools mcp-servers apps libs
  AGENTS.md CLAUDE.md README.md REVIEW.md
)

# Path/skill patterns only — returns 0 when the rename target is missing on disk.
orphan_target_missing() {
  local pattern_id="$1" token="$2"
  local bare="${token#/}"
  case "$pattern_id" in
    slash-token | path-skills-dir)
      [[ ! -d ".claude/skills/$bare" ]]
      ;;
    path-skill-md)
      [[ ! -f ".claude/skills/$bare/SKILL.md" && ! -f "$bare/SKILL.md" ]]
      ;;
    path-context-md)
      [[ ! -f "context/$bare.md" ]] \
        && ! find .claude/skills -path "*/context/$bare.md" -print -quit | grep -q .
      ;;
    path-skill-subdir)
      [[ ! -d ".claude/skills/$bare" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# Record one `path:line:text` grep hit: bump counters, track the file under the
# old/new bucket, and emit the Match/--- output pair. Mutates the run_pattern
# script-globals (hit_count, total_matches, file_hits, old_files, new_files).
record_hit() {
  local hit="$1" id="$2" label="$3"
  local path rest line_num text
  path="${hit%%:*}"
  rest="${hit#*:}"
  line_num="${rest%%:*}"
  text="${rest#*:}"
  hit_count=$((hit_count + 1))
  total_matches=$((total_matches + 1))
  file_hits["$path"]=1
  if [[ "$label" == "old" ]]; then
    old_files["$path"]=1
  else
    new_files["$path"]=1
  fi
  printf 'Match: %s:%s | pattern=%s | excerpt=%s\n' \
    "$path" "$line_num" "$id" "$(trim_excerpt "$text")"
  if [[ "$MODE" == "orphans" && "$label" == "old" ]] && orphan_target_missing "$id" "$OLD_TOKEN"; then
    printf 'Orphan (broken): %s:%s | pattern=%s\n' "$path" "$line_num" "$id"
    orphan_broken=$((orphan_broken + 1))
  elif [[ "$MODE" == "orphans" && "$label" == "old" ]]; then
    case "$id" in
      slash-token | path-skills-dir | path-skill-md | path-context-md | path-skill-subdir)
        printf 'Stale-but-functional: %s:%s | pattern=%s\n' "$path" "$line_num" "$id"
        stale_functional=$((stale_functional + 1))
        ;;
    esac
  fi
  printf '%s\n' '---'
}

run_pattern() {
  local token="$1" label="$2"
  local id triage template regex hit_count bare_token hit
  while IFS=$'\t' read -r id triage template; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    regex="$(rename_expand_template "$template" "$token" "")"
    [[ -z "$regex" ]] && continue
    hit_count=0
    if [[ "$id" == "slash-token" ]]; then
      bare_token="${token#/}"
      while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        # Fixed-string grep over-matches; keep only lines bearing the slash form.
        local text="${hit#*:}"
        text="${text#*:}"
        [[ "$text" == *"$token"* || "$text" == *"/$bare_token"* ]] || continue
        record_hit "$hit" "$id" "$label"
      done < <(git grep -nF -e "$bare_token" -- "${GREP_PATHS[@]}" 2>/dev/null \
        | grep -v '^\.work/' || true)
    else
      while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        record_hit "$hit" "$id" "$label"
      done < <(git grep -n -E "$regex" -- "${GREP_PATHS[@]}" 2>/dev/null \
        | grep -v '^\.work/' || true)
    fi
    printf 'Pattern: %s | triage=%s | hits=%s\n' "$id" "$triage" "$hit_count"
  done <"$REGISTRY"
}

run_pattern "$OLD_TOKEN" "old"
if [[ "$MODE" == "half-rename" || "$MODE" == "orphans" ]] && [[ -n "$NEW_TOKEN" ]]; then
  run_pattern "$NEW_TOKEN" "new"
fi

half_count=0
if [[ "$MODE" == "half-rename" ]]; then
  for path in "${!old_files[@]}"; do
    [[ -n "${new_files[$path]:-}" ]] || continue
    half_count=$((half_count + 1))
    printf 'Half-rename file: %s\n' "$path"
  done
  printf 'Half-rename files: %s\n' "$half_count"
fi

if [[ "$MODE" == "orphans" ]]; then
  printf 'Orphans (broken): %s\n' "$orphan_broken"
  printf 'Stale-but-functional: %s\n' "$stale_functional"
fi

printf 'Files with matches: %s\n' "${#file_hits[@]}"
printf 'Total matches: %s\n' "$total_matches"
exit 0
