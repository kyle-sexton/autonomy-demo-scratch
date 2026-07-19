#!/usr/bin/env bash
# Find identical non-trivial lines repeated across markdown files.
#
# Output: Count, Literal, Files blocks; trailing Summary line.
# Exit: always 0.
set -u

readonly TRIPLICATION_THRESHOLD="${TRIPLICATION_THRESHOLD:-3}"
readonly MIN_LINE_LENGTH="${MIN_LINE_LENGTH:-48}"

PATHS_FILE=""
MIN_LEN="$MIN_LINE_LENGTH"

usage() {
  cat <<EOF
find-literal-triplication.sh — emit repeated non-trivial lines across files.

Threshold: TRIPLICATION_THRESHOLD=${TRIPLICATION_THRESHOLD} (env override).
Default corpus: tracked *.md under repo root (excludes .work/, node_modules/).

Usage:
  find-literal-triplication.sh [--paths-file <file>] [--min-length N]
  find-literal-triplication.sh --help

Exit: always 0.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths-file)
      [[ $# -ge 2 ]] || {
        echo "find-literal-triplication: --paths-file requires a value" >&2
        exit 2
      }
      PATHS_FILE="${2:-}"
      shift 2
      ;;
    --min-length)
      [[ $# -ge 2 ]] || {
        echo "find-literal-triplication: --min-length requires a value" >&2
        exit 2
      }
      MIN_LEN="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "find-literal-triplication: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
[[ -n "$repo_root" ]] || {
  echo "Summary: hits=0 threshold=$TRIPLICATION_THRESHOLD"
  exit 0
}
cd "$repo_root" || exit 0

mapfile -t FILES < <(
  if [[ -n "$PATHS_FILE" && -f "$PATHS_FILE" ]]; then
    tr -d '\r' <"$PATHS_FILE"
  else
    git ls-files '*.md' 2>/dev/null | tr -d '\r' | grep -vE '^\.work/|node_modules/' || true
  fi
)

[[ ${#FILES[@]} -gt 0 ]] || {
  echo "Summary: hits=0 threshold=$TRIPLICATION_THRESHOLD"
  exit 0
}

hits="$(
  python3 - "$MIN_LEN" "$TRIPLICATION_THRESHOLD" "${FILES[@]}" <<'PY'
import sys
from collections import defaultdict

min_len = int(sys.argv[1])
threshold = int(sys.argv[2])
paths = sys.argv[3:]
by_line = defaultdict(set)
for path in paths:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.rstrip("\n\r")
                stripped = line.strip()
                if len(stripped) < min_len:
                    continue
                if stripped.startswith("#"):
                    continue
                by_line[stripped].add(path)
    except OSError:
        continue
out = []
for literal, files in sorted(by_line.items(), key=lambda kv: (-len(kv[1]), kv[0])):
    if len(files) < threshold:
        continue
    out.append((len(files), literal, sorted(files)))
for count, literal, files in out:
    print(f"Count: {count}")
    print(f"Literal: {literal}")
    print(f"Files: {';'.join(files)}")
    print()
print(f"Summary: hits={len(out)} threshold={threshold}")
PY
)"

printf '%s\n' "$hits"
