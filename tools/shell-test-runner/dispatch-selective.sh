# --files / --changed-since selective dispatch — sourced by run.sh, not executed directly.
# shellcheck source=run-policy.sh
# shellcheck disable=SC2154  # RERUN_ALL_TRIGGERS from run-policy.sh when sourced

# Argument parsing — positional ROOT_DIR + optional flags.
#
#   bash tools/run-shell-tests.sh                 # default: ROOT_DIR=repo root
#   bash tools/run-shell-tests.sh <dir>           # ROOT_DIR=<dir>
#   bash tools/run-shell-tests.sh [<dir>] --files <p>...
#                                                 # explicit test list
#                                                 # --files is variadic to argv end
#   bash tools/run-shell-tests.sh [<dir>] --changed-since <ref>
#                                                 # derive impacted tests via
#                                                 # `git diff <ref>...HEAD`
#
# Kill switch: BASH_TEST_SELECTIVE_DISPATCH_ENABLED=false disables filtering
# entirely (full-suite glob), mirroring the round-3 A6 scheduler kill switch.
parse_runner_args() {
  ROOT_DIR=""
  SELECTIVE_FILES=()
  CHANGED_SINCE_REF=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --files)
        shift
        while [[ $# -gt 0 ]]; do
          SELECTIVE_FILES+=("$1")
          shift
        done
        ;;
      --changed-since)
        if [[ $# -lt 2 ]]; then
          printf 'run-shell-tests: --changed-since requires a git ref\n' >&2
          exit 2
        fi
        CHANGED_SINCE_REF="$2"
        shift 2
        ;;
      --*)
        printf 'run-shell-tests: unknown flag: %s\n' "$1" >&2
        exit 2
        ;;
      *)
        if [[ -z "$ROOT_DIR" ]]; then
          ROOT_DIR="$1"
        else
          printf 'run-shell-tests: unexpected positional arg: %s (only one ROOT_DIR allowed)\n' "$1" >&2
          exit 2
        fi
        shift
        ;;
    esac
  done
  ROOT_DIR="${ROOT_DIR:-$REPO_ROOT}"
  cd "$ROOT_DIR" || exit 2
  scrub_git_hook_env
}

# Round-4 A1: selective dispatch (--files / --changed-since).
#
# --files: replace TESTS with explicit paths (made ROOT_DIR-relative).
# --changed-since: derive impacted tests from `git diff <ref>...HEAD`
#   plus uncommitted changes, applying the dispatch rule:
#     1. Changed *.test.sh -> include directly
#     2. Changed *.sh -> include sibling *.test.sh + glob siblings
#        (kebab-suffix -*.test.sh splits) + text-grep matches across TESTS
#     3. Must-rerun-all trigger matched -> full suite
#
# Kill switch: BASH_TEST_SELECTIVE_DISPATCH_ENABLED=false skips filtering
# entirely so the round-3 A6 longest-first scheduler still sees the full
# glob. Mirrors the scheduler's own kill switch.
apply_selective_dispatch() {
  [[ "${BASH_TEST_SELECTIVE_DISPATCH_ENABLED:-true}" == "true" ]] || return 0

  # --files takes precedence over --changed-since.
  if [[ ${#SELECTIVE_FILES[@]} -gt 0 ]]; then
    local filtered=() abs
    for abs in "${SELECTIVE_FILES[@]}"; do
      # Make ROOT_DIR-relative; the prefix strip is a no-op on already-relative paths.
      filtered+=("${abs#"$ROOT_DIR"/}")
    done
    TESTS=("${filtered[@]}")
    return 0
  fi

  [[ -n "$CHANGED_SINCE_REF" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0

  # Validate the ref before diffing. `git diff` swallows unknown-ref errors
  # with 2>/dev/null below, which would produce an empty `changed` set and
  # silently exit 0 with zero tests run — a false-green path that defeats
  # the safety of selective dispatch. Fail fast with exit 2 instead.
  if ! git rev-parse --verify --quiet "$CHANGED_SINCE_REF^{commit}" >/dev/null 2>&1; then
    printf 'run-shell-tests: --changed-since: invalid or unknown ref: %s\n' \
      "$CHANGED_SINCE_REF" >&2
    exit 2
  fi

  # Collect changed paths: committed diff + uncommitted (modified/untracked).
  local changed=() f
  while IFS= read -r f; do
    [[ -n "$f" ]] && changed+=("$f")
  done < <(git diff --name-only "$CHANGED_SINCE_REF"...HEAD 2>/dev/null)
  while IFS= read -r f; do
    [[ -n "$f" ]] && changed+=("$f")
  done < <(git ls-files --modified --others --exclude-standard 2>/dev/null)

  # Must-rerun-all check.
  local trigger
  for trigger in "${RERUN_ALL_TRIGGERS[@]}"; do
    for f in "${changed[@]}"; do
      if [[ "$f" == "$trigger" ]]; then
        printf 'run-shell-tests: must-rerun-all trigger matched (%s); running full suite.\n' \
          "$trigger" >&2
        return 0
      fi
    done
  done

  # Build impacted set (associative array prevents duplicates).
  # Files deleted or renamed between <ref>...HEAD still appear in `git diff
  # --name-only` output — guard with `-f` so the replay loop doesn't try to
  # `bash <missing-path>` and convert a non-behavioral refactor into a
  # failing selective run.
  local impacted=()
  declare -A seen=()
  local base sibling t needle match
  for f in "${changed[@]}"; do
    if [[ "$f" == *.test.sh ]]; then
      if [[ -f "$f" && -z "${seen[$f]:-}" ]]; then
        impacted+=("$f")
        seen["$f"]=1
      fi
      continue
    fi
    if [[ "$f" == *.sh ]]; then
      base="${f%.sh}"
      sibling="${base}.test.sh"
      if [[ -f "$sibling" && -z "${seen[$sibling]:-}" ]]; then
        impacted+=("$sibling")
        seen["$sibling"]=1
      fi
      # Glob siblings (-*.test.sh round-3 splits)
      for t in "${TESTS[@]}"; do
        if [[ "$t" == "$base"-*.test.sh && -z "${seen[$t]:-}" ]]; then
          impacted+=("$t")
          seen["$t"]=1
        fi
      done
      # Text-grep — any TESTS body referencing this SUT path
      needle="${f##*/}"
      if [[ ${#TESTS[@]} -gt 0 ]]; then
        while IFS= read -r match; do
          [[ -z "$match" ]] && continue
          [[ -n "${seen[$match]:-}" ]] && continue
          impacted+=("$match")
          seen["$match"]=1
        done < <(grep -lF "$needle" "${TESTS[@]}" 2>/dev/null)
      fi
    fi
  done

  if [[ ${#impacted[@]} -eq 0 ]]; then
    printf 'run-shell-tests: No impacted *.test.sh files for --changed-since %s\n' \
      "$CHANGED_SINCE_REF" >&2
    TESTS=()
    return 0
  fi
  TESTS=("${impacted[@]}")
}

# Detect a Windows/Git Bash shell (MSYS2/Cygwin). Wrapped so tests can fake it.
_runner_is_windows_shell() {
  case "${OSTYPE:-}" in
    msys* | cygwin* | win32) return 0 ;;
    *) return 1 ;;
  esac
}

# Is the runner's stderr an interactive terminal? Wrapped so tests can fake it.
# The advisory targets a human at a prompt; captured / piped / file-redirected
# callers (the pre-push walltime lane, CI, the test suite) must stay silent.
_runner_stderr_is_interactive() {
  [[ -t 2 ]]
}

# Advisory hint (interactive Windows/Git Bash only): a bare full-suite run pays the
# MSYS2 fork tax (10-90x Linux), so point the user at selective dispatch; CI (Linux)
# runs the full suite as the authoritative gate. stderr-only; no behavior/exit-code
# change. Fires only for a bare full-suite run, on Windows, outside CI, with an
# interactive stderr; never on Linux/macOS, CI, or any caller that redirects the
# runner's stderr (pre-push lane, tests). Silence: BASH_TEST_FULLSUITE_HINT_ENABLED=false.
full_suite_advisory() {
  [[ "${BASH_TEST_FULLSUITE_HINT_ENABLED:-true}" == "true" ]] || return 0
  [[ "${BASH_TEST_SELECTIVE_DISPATCH_ENABLED:-true}" == "true" ]] || return 0
  [[ -z "${CI:-}" ]] || return 0
  _runner_stderr_is_interactive || return 0
  _runner_is_windows_shell || return 0
  ((${#SELECTIVE_FILES[@]} == 0)) || return 0
  [[ -z "${CHANGED_SINCE_REF:-}" ]] || return 0
  printf 'run-shell-tests: full suite is fork-tax-slow on Windows/Git Bash. For local iteration use --changed-since origin/main (CI runs the full suite as the gate). Silence: BASH_TEST_FULLSUITE_HINT_ENABLED=false.\n' >&2
}
