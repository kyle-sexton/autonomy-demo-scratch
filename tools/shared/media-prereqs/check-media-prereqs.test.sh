#!/usr/bin/env bash
# Tests for check-media-prereqs.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

CHECK="$SCRIPT_DIR/check-media-prereqs.sh"
FAILED=0

assert_exit "--help exits 0" 0 "$(
  bash "$CHECK" --help >/dev/null 2>&1
  echo $?
)"

out="$(bash "$CHECK" --consumer youtube)"
assert_contains "ffmpeg tool line" "$out" "Tool: ffmpeg"
assert_contains "yt-dlp tool line" "$out" "Tool: yt-dlp"
assert_not_contains "no magick for youtube" "$out" "Tool: ImageMagick"
assert_contains "summary line" "$out" "Summary required missing:"

out_all="$(bash "$CHECK" --consumer all)"
assert_contains "magick for all" "$out_all" "Tool: ImageMagick"
assert_contains "playwright for all" "$out_all" "Tool: Playwright Chromium"
assert_contains "playwright skipped without dir" "$out_all" "Status: skipped"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: check-media-prereqs.sh tests passed"
