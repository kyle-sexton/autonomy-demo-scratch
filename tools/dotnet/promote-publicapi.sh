#!/usr/bin/env bash
# Promote PublicAPI.Unshipped.txt entries into PublicAPI.Shipped.txt for every
# publishable Platform.* library. Run at NuGet release boundary — once the
# unshipped surface is committed to the next release, this folds it into the
# shipped baseline so subsequent additions/changes show up cleanly in diffs.
#
# Behavior per (Shipped, Unshipped) pair:
#   1. Each non-header line in Unshipped is either an addition (`Foo.Bar`) or
#      a removal (`*REMOVED*Foo.Bar`).
#   2. For removals: drop the matching `Foo.Bar` line from Shipped (RS0017
#      contract).
#   3. For additions: merge into Shipped.
#   4. Sort + dedupe Shipped (LC_ALL=C, stable across platforms).
#   5. Reset Unshipped to header-only (`#nullable enable`).
#
# Idempotent: running on already-promoted libs is a no-op (Unshipped is
# header-only → nothing to merge).
#
# Cross-platform: pure bash + coreutils (sort, grep, mktemp). No GNU-isms.
# Discovers single-target top-level files AND multi-target subdirectory
# files (`PublicAPI/<TFM>/PublicAPI.{Shipped,Unshipped}.txt`) per Microsoft
# canonical layout.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIBS_DIR="${REPO_ROOT}/libs/dotnet"
HEADER='#nullable enable'

if [[ ! -d "$LIBS_DIR" ]]; then
  echo "ERROR: libs/dotnet not found at $LIBS_DIR" >&2
  exit 1
fi

promote_pair() {
  local shipped="$1" unshipped="$2"
  local rel_shipped="${shipped#"$REPO_ROOT/"}"

  if [[ ! -f "$shipped" || ! -f "$unshipped" ]]; then
    return 0
  fi

  local additions removals
  additions=$(grep -v -E '^(#nullable enable|\*REMOVED\*|$)' "$unshipped" || true)
  removals=$(grep -E '^\*REMOVED\*' "$unshipped" | sed 's/^\*REMOVED\*//' || true)

  if [[ -z "$additions" && -z "$removals" ]]; then
    echo "skip:    $rel_shipped (no unshipped changes)"
    return 0
  fi

  local tmp_shipped tmp_body
  tmp_shipped=$(mktemp)
  tmp_body=$(mktemp)
  trap 'rm -f "$tmp_shipped" "$tmp_body"' RETURN

  grep -v -E '^(#nullable enable|$)' "$shipped" >"$tmp_body" || true

  if [[ -n "$additions" ]]; then
    printf '%s\n' "$additions" >>"$tmp_body"
  fi

  if [[ -n "$removals" ]]; then
    # One fixed-string, whole-line pass drops every removal without rescanning
    # tmp_body per removed entry.
    grep -F -v -x -f <(printf '%s\n' "$removals") "$tmp_body" >"${tmp_body}.new" || true
    mv "${tmp_body}.new" "$tmp_body"
  fi

  {
    printf '%s\n' "$HEADER"
    LC_ALL=C sort -u "$tmp_body"
  } >"$tmp_shipped"

  mv "$tmp_shipped" "$shipped"
  printf '%s\n' "$HEADER" >"$unshipped"

  echo "promote: $rel_shipped"
}

shopt -s nullglob

for shipped in "$LIBS_DIR"/Platform.*/PublicAPI.Shipped.txt \
  "$LIBS_DIR"/Platform.*/PublicAPI/*/PublicAPI.Shipped.txt; do
  unshipped="${shipped%Shipped.txt}Unshipped.txt"
  promote_pair "$shipped" "$unshipped"
done

echo
echo "Done. Review with: git diff -- 'libs/dotnet/Platform.*/PublicAPI*.txt'"
