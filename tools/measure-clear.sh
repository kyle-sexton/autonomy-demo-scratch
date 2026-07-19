#!/usr/bin/env bash
# Measure SessionStart hook wall-clock per matcher group.
#
# Runs each SessionStart hook N times via $EPOCHREALTIME (bash 5+), reports
# min/median/max per hook, then per matcher group the SLOWEST hook — CC runs
# matching hooks in PARALLEL, so a group's blocking wall-clock is its slowest
# hook, not the sum. Stdin: empty JSON object (SessionStart schema ignores it).
#
# Usage:
#   bash tools/measure-clear.sh                # warm run (cache as-is)
#   bash tools/measure-clear.sh --cold         # delete msbuild cache first
#   bash tools/measure-clear.sh --runs 5       # change run count (default 3)
#
# Exit codes:
#   0  Measurement completed (regardless of individual hook exit codes)
#   1  Usage error or missing prerequisite (bash <5, hook script absent)
#
# Output: human-readable table on stdout. No JSONL append, no side effects
# beyond optional --cold cache deletion.

# Hooks may exit non-zero (e.g. dotnet absent on a probe machine) — we still
# want timing data. Omit -e; check exit codes explicitly.
set -uo pipefail

if ((BASH_VERSINFO[0] < 5)); then
  echo "Error: bash 5.0+ required for \$EPOCHREALTIME (found $BASH_VERSION)" >&2
  exit 1
fi

RUNS=3
COLD=false
while (($#)); do
  case "$1" in
    --cold) COLD=true ;;
    --runs)
      shift
      RUNS="${1:-3}"
      ;;
    --help | -h)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "Error: unknown arg '$1' (try --help)" >&2
      exit 1
      ;;
  esac
  shift
done

REPO=$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
[[ -n "$REPO" ]] || {
  echo "Error: not a git repo" >&2
  exit 1
}

HOOK_DIR="$REPO/.claude/hooks"
# SessionStart hooks by matcher group. CC runs all matching hooks in PARALLEL,
# so each group's blocking wall-clock = its slowest hook (verified Tier-0 from
# overlapping execution windows in .claude/observability/hook-events.jsonl).
CLEAR_HOOKS=(branch-awareness)                                                      # startup|clear|resume
STARTUP_HOOKS=(worktree-setup onboard-drift cc-telemetry-ensure msbuild-introspect) # startup|resume
HOOKS=("${CLEAR_HOOKS[@]}" "${STARTUP_HOOKS[@]}")

for h in "${HOOKS[@]}"; do
  [[ -x "$HOOK_DIR/$h.sh" ]] || {
    echo "Error: hook $HOOK_DIR/$h.sh not executable" >&2
    exit 1
  }
done

if $COLD; then
  # Resolve THIS worktree's cache file via the same helper the hook uses, so
  # --cold deletes the file the hook will actually re-create (per-worktree keyed).
  # shellcheck source=../.claude/hooks/hook-utils.sh
  source "$REPO/.claude/hooks/hook-utils.sh"
  cache_path=$(hook::msbuild_cache_file "$REPO")
  if [[ -f "$cache_path" ]]; then
    rm -f "$cache_path"
    echo "Cold: removed $cache_path"
  else
    echo "Cold: no cache at $cache_path (already cold)"
  fi
fi

export CLAUDE_PROJECT_DIR="$REPO"

# Per-hook median accumulator — group-max at end for the parallel wall-clock estimate.
declare -A MEDIAN_MS

# Convert $EPOCHREALTIME float seconds (e.g. 1234567890.123456) to microseconds.
epoch_to_us() {
  local int=${1%.*} frac=${1#*.}
  # Pad/truncate fractional component to exactly 6 digits (microseconds).
  frac=${frac}000000
  frac=${frac:0:6}
  printf '%s\n' "$((int * 1000000 + 10#$frac))"
}

elapsed_ms() {
  # $1=start ($EPOCHREALTIME float seconds), $2=end (same)
  local start_us end_us
  start_us=$(epoch_to_us "$1")
  end_us=$(epoch_to_us "$2")
  echo $(((end_us - start_us) / 1000))
}

run_hook_once() {
  local script="$1" source="${2:-startup}"
  local start end
  start=$EPOCHREALTIME
  printf '{"source":"%s"}\n' "$source" | bash "$script" >/dev/null 2>&1
  end=$EPOCHREALTIME
  elapsed_ms "$start" "$end"
}

printf '\n== SessionStart hook timing (%s, %d runs each) ==\n' "$($COLD && echo cold || echo warm)" "$RUNS"
printf '%-22s' "Hook"
for ((i = 1; i <= RUNS; i++)); do printf ' run%-5d' "$i"; done
printf ' %6s %6s %6s\n' "min" "med" "max"

for h in "${HOOKS[@]}"; do
  printf '%-22s' "$h.sh"
  # Measure each hook with the source it actually sees: CLEAR_HOOKS on /clear,
  # the rest on startup. branch-awareness skips its blocking fetch on /clear, so
  # measuring it with source=clear reflects the real /clear path.
  src=startup
  for c in "${CLEAR_HOOKS[@]}"; do
    [[ "$h" == "$c" ]] && src=clear
  done
  declare -a times=()
  for ((i = 0; i < RUNS; i++)); do
    ms=$(run_hook_once "$HOOK_DIR/$h.sh" "$src")
    times+=("$ms")
    printf ' %6dms' "$ms"
  done
  mapfile -t sorted < <(printf '%s\n' "${times[@]}" | sort -n)
  min=${sorted[0]}
  max=${sorted[-1]}
  mid_idx=$((RUNS / 2))
  median=${sorted[$mid_idx]}
  MEDIAN_MS[$h]=$median
  printf ' %6d %6d %6d\n' "$min" "$median" "$max"
done

# CC runs all matching hooks in PARALLEL, so each matcher group's blocking
# wall-clock ≈ the SLOWEST hook in that group, not the sum.
group_max() {
  local max=0 h
  for h in "$@"; do
    ((MEDIAN_MS[$h] > max)) && max=${MEDIAN_MS[$h]}
  done
  printf '%s\n' "$max"
}
clear_max=$(group_max "${CLEAR_HOOKS[@]}")
startup_max=$(group_max "${STARTUP_HOOKS[@]}")

printf '\n/clear blocking  (startup|clear|resume, %d hook):  ~%dms (%.2fs) — slowest of group\n' \
  "${#CLEAR_HOOKS[@]}" "$clear_max" "$(awk "BEGIN{printf \"%.2f\", $clear_max/1000}")"
printf 'startup/resume   (startup|resume, %d hooks): ~%dms (%.2fs) — slowest of group\n' \
  "${#STARTUP_HOOKS[@]}" "$startup_max" "$(awk "BEGIN{printf \"%.2f\", $startup_max/1000}")"
printf 'Hooks run in parallel: group wall-clock = slowest hook, not sum.\n'

exit 0
