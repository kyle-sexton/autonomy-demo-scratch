#!/usr/bin/env bash
# Dispatch lint checks from the per-ecosystem surface at .claude/ecosystems/*.yaml.
#
# Output (per ecosystem): Ecosystem, Command, Status, Detail; trailing Summary line.
#
# Usage:
#   bash tools/lint/run-lint.sh [--ecosystem <name>] [--all] [--fix] [--dry-run]
#
# Exit: 0 pass/skipped; 1 fail; 2 usage error.
set -euo pipefail

ECOSYSTEM=""
MODE="check"
RUN_ALL=0
DRY_RUN=0

usage() {
  cat <<'EOF'
run-lint.sh — dispatch lint commands from .claude/ecosystems/*.yaml.

Usage:
  run-lint.sh [--ecosystem <name>] [--all] [--fix] [--dry-run]
  run-lint.sh --help

Reads the canonical check-cmd/fix-cmd verbs from .claude/ecosystems/<eco>.yaml.
Auto-detect (no filter): match changed files against each ecosystem's globs.

Exit: 0 pass; 1 fail; 2 usage.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ecosystem)
      ECOSYSTEM="${2:-}"
      shift 2
      ;;
    --all)
      RUN_ALL=1
      shift
      ;;
    --fix)
      MODE="fix"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "run-lint.sh: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$repo_root" ]]; then
  echo "run-lint.sh: not a git repository" >&2
  exit 2
fi
cd "$repo_root" || exit 2

ECO_DIR="$repo_root/.claude/ecosystems"
if [[ ! -d "$ECO_DIR" ]]; then
  echo "run-lint.sh: missing ecosystem config dir ($ECO_DIR)" >&2
  exit 2
fi

mapfile -t CHANGED < <(git diff --name-only HEAD 2>/dev/null | tr -d '\r')
if [[ ${#CHANGED[@]} -eq 0 ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    path="${line#?? }"
    path="${path#\"}"
    path="${path%\"}"
    CHANGED+=("$path")
  done < <(git status --porcelain 2>/dev/null | tr -d '\r')
fi

resolve_ec_bin() {
  if command -v ec >/dev/null 2>&1; then
    printf '%s' ec
  elif command -v editorconfig-checker >/dev/null 2>&1; then
    printf '%s' editorconfig-checker
  elif command -v ec-windows-amd64 >/dev/null 2>&1; then
    printf '%s' ec-windows-amd64
  else
    printf '%s' ec
  fi
}

# Extract a single-line top-level scalar value for KEY from a flat ecosystem
# YAML file. Strips one layer of matching quotes; returns "null" verbatim; rc 1
# when the key is absent.
yaml_scalar() {
  local file="$1" key="$2" line val
  line="$(grep -m1 -E "^${key}:" "$file" 2>/dev/null | tr -d '\r' || true)"
  [[ -z "$line" ]] && return 1
  val="${line#"${key}":}"
  val="${val#"${val%%[![:space:]]*}"}"
  if [[ ${#val} -ge 2 && "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
    val="${val:1:${#val}-2}"
  elif [[ ${#val} -ge 2 && "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

# Emit one glob per line from the flow-style `globs: [...]` array.
yaml_globs() {
  local file="$1" line inner item
  line="$(grep -m1 -E "^globs:" "$file" 2>/dev/null | tr -d '\r' || true)"
  [[ "$line" != *\[* ]] && return 0
  inner="${line#*[}"
  inner="${inner%]*}"
  local IFS=','
  for item in $inner; do
    item="${item//\"/}"
    item="${item//\'/}"
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

# A glob matches a changed path when: `**` matches any path; a `**`-bearing
# glob matches by its literal prefix (before `**`) and suffix (after the last
# `*`); a leading-`*` glob matches by suffix; otherwise an exact path match.
glob_matches_changed() {
  local glob="$1" path prefix suffix
  if [[ "$glob" == "**" ]]; then
    return 0
  fi
  for path in "${CHANGED[@]}"; do
    [[ -z "$path" ]] && continue
    if [[ "$glob" == *"**"* ]]; then
      prefix="${glob%%\*\**}"
      suffix="${glob##*\*}"
      [[ "$path" == "$prefix"* && "$path" == *"$suffix" ]] && return 0
    elif [[ "$glob" == \** ]]; then
      suffix="${glob#\*}"
      [[ "$path" == *"$suffix" ]] && return 0
    else
      [[ "$path" == "$glob" ]] && return 0
    fi
  done
  return 1
}

should_run_ecosystem() {
  local eco="$1" file="$2" g
  if [[ "$RUN_ALL" -eq 1 || "$ECOSYSTEM" == "$eco" || "$ECOSYSTEM" == "all" ]]; then
    return 0
  fi
  if [[ -n "$ECOSYSTEM" ]]; then
    return 1
  fi
  [[ ${#CHANGED[@]} -eq 0 ]] && return 1
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    glob_matches_changed "$g" && return 0
  done < <(yaml_globs "$file")
  return 1
}

substitute_placeholders() {
  local cmd="$1"
  local files=() path
  for path in "${CHANGED[@]}"; do
    [[ "$path" == *.sh ]] && files+=("$path")
  done
  local file_args=""
  if ((${#files[@]} > 0)); then
    file_args="${files[*]}"
  fi
  cmd="${cmd//\$REPO_ROOT/$repo_root}"
  cmd="${cmd//<files>/$file_args}"
  cmd="${cmd//\$EC_BIN/$(resolve_ec_bin)}"
  printf '%s' "$cmd"
}

pass=0 fail=0 skip=0 total=0
shopt -s nullglob
for file in "$ECO_DIR"/*.yaml; do
  case "$file" in
    *.local.yaml) continue ;;
  esac
  eco="$(basename "$file" .yaml)"
  [[ "$(yaml_scalar "$file" enabled || true)" == "false" ]] && continue
  should_run_ecosystem "$eco" "$file" || continue
  total=$((total + 1))
  printf 'Ecosystem: %s\n' "$eco"

  if [[ "$MODE" == "fix" ]]; then
    cmd="$(yaml_scalar "$file" fix-cmd || true)"
    if [[ -z "$cmd" || "$cmd" == "null" ]]; then
      printf 'Command: (none)\n'
      printf 'Status: skip\n'
      printf 'Detail: no auto-fix available for %s\n' "$eco"
      skip=$((skip + 1))
      continue
    fi
  else
    cmd="$(yaml_scalar "$file" check-cmd || true)"
    if [[ -z "$cmd" || "$cmd" == "null" ]]; then
      printf 'Command: (none)\n'
      printf 'Status: skip\n'
      printf 'Detail: no %s command configured\n' "$MODE"
      skip=$((skip + 1))
      continue
    fi
  fi

  cmd="$(substitute_placeholders "$cmd")"
  printf 'Command: %s\n' "$cmd"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Status: planned\n'
    printf 'Detail: dry-run\n'
    skip=$((skip + 1))
    continue
  fi
  if ! output="$(cd "$repo_root" && eval "$cmd" 2>&1)"; then
    printf 'Status: fail\n'
    printf 'Detail: %s\n' "$(printf '%s\n' "$output" | head -1)"
    fail=$((fail + 1))
  else
    printf 'Status: pass\n'
    printf 'Detail: ok\n'
    pass=$((pass + 1))
  fi
done
shopt -u nullglob

printf 'Summary: ecosystems=%s pass=%s fail=%s skip=%s\n' "$total" "$pass" "$fail" "$skip"

if [[ "$total" -eq 0 ]]; then
  printf 'Detail: no ecosystems matched — use --all or --ecosystem <name>\n'
  exit 0
fi
[[ "$fail" -eq 0 ]]
exit $?
