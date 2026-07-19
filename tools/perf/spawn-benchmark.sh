#!/usr/bin/env bash
# Micro-benchmark for process-spawn cost on this machine.
#
# The shell test suite's walltime is dominated by process-spawn cost ×
# spawn count (see .claude/rules/bash/testing.md "Walltime budget" — the
# documented fork floor is ~33ms bash / ~57ms jq / ~37ms git on Git Bash
# for Windows). This script measures the CURRENT per-spawn cost so perf
# claims and machine-tuning changes (Defender exclusions, /etc/passwd
# generation) are verifiable before/after, per bash/testing.md
# "Measurement methodology".
#
# Measures p50/p95 wall-clock of:
#   bash      — `bash -c true` (cold bash start: the per-assertion SUT cost)
#   subshell  — `$(:)` (fork without exec: command-substitution cost)
#   git       — `git rev-parse --show-toplevel` (repo-context git spawn)
#   jq        — `jq -cn '{}'` (JSON tool spawn: per-payload synthesis cost)
#
# Usage:
#   bash tools/perf/spawn-benchmark.sh                # human-readable table
#   bash tools/perf/spawn-benchmark.sh --json         # one JSON object to stdout
#   bash tools/perf/spawn-benchmark.sh --iterations 50
#   bash tools/perf/spawn-benchmark.sh --help
#
# Exit: 0 on success, 2 on usage error.

set -uo pipefail

if ((BASH_VERSINFO[0] < 5)); then
  printf 'spawn-benchmark: bash 5.0+ required (found %s)\n' "$BASH_VERSION" >&2
  exit 2
fi

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ITERATIONS=25
EMIT_JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --json)
      EMIT_JSON=true
      shift
      ;;
    --iterations)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -lt 3 ]]; then
        printf 'spawn-benchmark: --iterations requires an integer >= 3\n' >&2
        exit 2
      fi
      ITERATIONS="$2"
      shift 2
      ;;
    *)
      printf 'spawn-benchmark: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

# Per-iteration wall-clock in microseconds via $EPOCHREALTIME (no `date`
# fork). Results land in the caller-scope SAMPLES array.
SAMPLES=()
_time_one() {
  local start end start_s start_us end_s end_us
  start=$EPOCHREALTIME
  "$@" >/dev/null 2>&1
  end=$EPOCHREALTIME
  start_s=${start%.*} start_us=${start#*.}
  end_s=${end%.*} end_us=${end#*.}
  # Strip leading zeros (10#) to avoid octal interpretation of e.g. "089".
  SAMPLES+=($(((end_s - start_s) * 1000000 + 10#$end_us - 10#$start_us)))
}

# _subshell_probe — one fork without exec.
_subshell_probe() {
  local _x
  # shellcheck disable=SC2034  # value unused; the fork is the measurement
  _x=$(:)
}

# percentile <pct> <sorted values...> — nearest-rank percentile, echoed in ms.
percentile() {
  local pct="$1"
  shift
  local n=$#
  local rank=$(((pct * n + 99) / 100))
  [[ $rank -lt 1 ]] && rank=1
  local us
  us=$(printf '%s\n' "$@" | sort -n | sed -n "${rank}p")
  printf '%d' $((us / 1000))
}

declare -A P50 P95
KINDS=()

run_kind() {
  local kind="$1"
  shift
  SAMPLES=()
  local i
  # One untimed warm-up iteration so OS page-cache state is comparable
  # between runs.
  "$@" >/dev/null 2>&1
  for ((i = 0; i < ITERATIONS; i++)); do
    _time_one "$@"
  done
  KINDS+=("$kind")
  P50[$kind]=$(percentile 50 "${SAMPLES[@]}")
  P95[$kind]=$(percentile 95 "${SAMPLES[@]}")
}

run_kind bash bash -c true
run_kind subshell _subshell_probe
if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
  run_kind git git rev-parse --show-toplevel
fi
if command -v jq >/dev/null 2>&1; then
  run_kind jq jq -cn '{}'
fi

TS=$(printf '%(%Y-%m-%dT%H:%M:%S)T' -1)

if [[ "$EMIT_JSON" == "true" ]]; then
  out="{\"ts\":\"$TS\",\"iterations\":$ITERATIONS,\"host_os\":\"$(uname -s)\",\"results\":{"
  first=1
  for kind in "${KINDS[@]}"; do
    [[ $first -eq 1 ]] || out+=","
    first=0
    out+="\"$kind\":{\"ms_p50\":${P50[$kind]},\"ms_p95\":${P95[$kind]}}"
  done
  out+="}}"
  printf '%s\n' "$out"
else
  printf 'spawn-benchmark: %d iterations per kind (%s)\n' "$ITERATIONS" "$TS"
  printf '%-10s %10s %10s\n' KIND MS_P50 MS_P95
  for kind in "${KINDS[@]}"; do
    printf '%-10s %10d %10d\n' "$kind" "${P50[$kind]}" "${P95[$kind]}"
  done
fi
