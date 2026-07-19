#!/usr/bin/env bash
# Markdown target paths for /declutter and related consumers.
#
# Output: Markdown target count, Markdown target lines.
# Exit: always 0.
set -u

PATHS_FILE=""

usage() {
  cat <<'EOF'
list-md-targets.sh — emit markdown file paths for declutter/audit.

Usage:
  list-md-targets.sh
  list-md-targets.sh --paths-file <file>
  list-md-targets.sh --help

Default: porcelain uncommitted .md paths, lexically sorted.
--paths-file: one repo-relative path per line (blank lines ignored).

Exit: always 0.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths-file)
      PATHS_FILE="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "list-md-targets.sh: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
[[ -n "$repo_root" ]] && cd "$repo_root" 2>/dev/null || true

collect_paths() {
  if [[ -n "$PATHS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line//$'\r'/}"
      [[ -z "$line" ]] && continue
      printf '%s\n' "$line"
    done <"$PATHS_FILE"
    return
  fi

  git status --porcelain 2>/dev/null | while IFS= read -r line; do
    line="${line//$'\r'/}"
    [[ -z "$line" ]] && continue
    path="${line#?? }"
    path="${path#\"}"
    path="${path%\"}"
    [[ "$path" == *".md" ]] || continue
    printf '%s\n' "$path"
  done
}

mapfile -t targets < <(collect_paths | LC_ALL=C sort -u)
count="${#targets[@]}"

printf 'Markdown target count: %s\n' "$count"
for path in "${targets[@]}"; do
  printf 'Markdown target: %s\n' "$path"
done
exit 0
