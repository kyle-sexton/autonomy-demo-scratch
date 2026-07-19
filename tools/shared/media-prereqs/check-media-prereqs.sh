#!/usr/bin/env bash
# Media prerequisite facts for /youtube and /course-digest.
#
# Output: Tool, Status, Version, Required lines; Summary required missing.
# Exit: always 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/media-prereqs.sh
source "$SCRIPT_DIR/lib/media-prereqs.sh"

CONSUMER="all"
PLAYWRIGHT_EXTRACTION_DIR=""

usage() {
  cat <<'EOF'
check-media-prereqs.sh — emit media toolchain facts.

Usage:
  check-media-prereqs.sh --consumer youtube|course-digest|all
  check-media-prereqs.sh --consumer course-digest --playwright-extraction-dir <path>
  check-media-prereqs.sh --help

Exit: always 0.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --consumer)
      CONSUMER="${2:-}"
      shift 2
      ;;
    --playwright-extraction-dir)
      PLAYWRIGHT_EXTRACTION_DIR="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "check-media-prereqs.sh: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

want_ffmpeg=0 want_ytdlp=0 want_magick=0 want_playwright=0
case "$CONSUMER" in
  youtube)
    want_ffmpeg=1
    want_ytdlp=1
    ;;
  course-digest)
    want_ffmpeg=1
    want_magick=1
    want_playwright=1
    ;;
  all)
    want_ffmpeg=1
    want_ytdlp=1
    want_magick=1
    want_playwright=1
    ;;
  *)
    echo "check-media-prereqs.sh: invalid --consumer '$CONSUMER'" >&2
    exit 2
    ;;
esac

missing_required=0

emit_and_count() {
  local cmd="$1" display="$2" floor="$3" required="$4"
  local block status
  block="$(media_prereq_emit_fact "$cmd" "$display" "$floor" "$required")"
  printf '%s\n' "$block"
  status="$(printf '%s\n' "$block" | grep -m1 '^Status:' | sed 's/^Status: //')"
  if [[ "$required" == "true" && ("$status" == "missing" || "$status" == "below-floor") ]]; then
    missing_required=$((missing_required + 1))
  fi
}

[[ "$want_ffmpeg" -eq 1 ]] && emit_and_count ffmpeg ffmpeg 7.1 true
[[ "$want_ytdlp" -eq 1 ]] && emit_and_count yt-dlp yt-dlp 2026.7 false
[[ "$want_magick" -eq 1 ]] && emit_and_count magick ImageMagick 7.0 true

if [[ "$want_playwright" -eq 1 ]]; then
  pw_status="missing"
  pw_version="n/a"
  if [[ -z "$PLAYWRIGHT_EXTRACTION_DIR" ]]; then
    pw_status="skipped"
  elif [[ ! -f "$PLAYWRIGHT_EXTRACTION_DIR/package.json" ]] || ! grep -q '"playwright"' "$PLAYWRIGHT_EXTRACTION_DIR/package.json" 2>/dev/null; then
    pw_status="skipped"
  elif command -v npx >/dev/null 2>&1 && (cd "$PLAYWRIGHT_EXTRACTION_DIR" && npx playwright --version >/dev/null 2>&1); then
    pw_status="present"
    pw_version="$(cd "$PLAYWRIGHT_EXTRACTION_DIR" && npx playwright --version 2>/dev/null | tr -d '\r' | head -n1)"
    pw_version="$(media_prereq_parse_version "$pw_version")"
    pw_version="${pw_version:-unknown}"
  fi
  printf 'Tool: Playwright Chromium\n'
  printf 'Status: %s\n' "$pw_status"
  printf 'Version: %s\n' "$pw_version"
  printf 'Required: true\n'
  if [[ "$pw_status" == "missing" ]]; then
    missing_required=$((missing_required + 1))
  fi
fi

printf 'Summary required missing: %s\n' "$missing_required"
exit 0
