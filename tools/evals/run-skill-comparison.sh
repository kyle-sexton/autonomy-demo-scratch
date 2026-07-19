#!/usr/bin/env bash
# A/B skill-body comparison driver: snapshot the live working tree, spin up
# two detached worktrees (arm A = as-committed, arm B = relaxation patch
# applied uncommitted), run headless `claude -p` fixture trials per arm,
# capture scrubbed transcripts + meta, and tear down.
#
# Self-contained — all inputs arrive via args; no .work/ path assumptions.
# Promotes to tools/evals/ at slice close.
#
# Hub safety: NEVER `git worktree prune` (hub-global — can unregister
# concurrent sessions' worktrees). All teardown is path-scoped to this run's
# own tmpdir prefix. A pre/post refs digest fails loud if a run mutated
# shared refs (bypassPermissions does not fence git writes).
#
# Env: CLAUDE_BIN — claude binary override (tests point this at a stub).

set -euo pipefail

DEFAULT_STAGGER_SECONDS=45
DEFAULT_TIMEOUT_SECONDS=1800
STREAM_IDLE_TIMEOUT_MS=600000
SETTINGS_OVERRIDE_JSON='{"enabledPlugins":{"caveman@caveman":false}}'
WORKTREE_PREFIX_NAME="skill-comparison"
# Forbidden machine-path shapes asserted absent post-scrub (pre-registered in
# the slice PLAN — the hardcoded-path hook can't see shell redirects, so the
# driver owns this gate).
SCRUB_FORBIDDEN_REGEX_DEFAULT='C:\\\\|/Users/|AppData|/tmp/tmp\.'
# The repo hub root (bare-clone hub, or the repo root on a standard clone)
# leaks via git tool output in transcripts (`git worktree list`, `git
# rev-parse`) — a machine-layout path no user-dir rule covers. Derive it at
# runtime so the scrub table can rewrite every separator form to <REPO-HUB>
# and the forbidden gate catches any residual form.
REPO_HUB_DIR=""
if _hub_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [[ -n "$_hub_common_dir" ]]; then
  REPO_HUB_DIR="${_hub_common_dir%/*}"
fi
# Env-overridable so tests can simulate a leak shape no rule covers yet.
SCRUB_FORBIDDEN_REGEX="${SCRUB_FORBIDDEN_REGEX_OVERRIDE:-$SCRUB_FORBIDDEN_REGEX_DEFAULT}"
if [[ -z "${SCRUB_FORBIDDEN_REGEX_OVERRIDE:-}" && -n "$REPO_HUB_DIR" ]]; then
  # ERE form of the hub path matching any separator convention (/, \, \\).
  _hub_sep_class='[/\\]+'
  _hub_ere=$(printf '%s' "$REPO_HUB_DIR" | sed -e 's/[][\\.*^$|+?(){}]/\\&/g')
  SCRUB_FORBIDDEN_REGEX="${SCRUB_FORBIDDEN_REGEX}|${_hub_ere//\//$_hub_sep_class}"
fi

PROMPT_FILE=""
PATCH_FILE=""
MODEL=""
TRIALS=""
LABEL=""
OUT_DIR=""
DRY_RUN=false
KEEP_WORKTREES=false
STAGGER_SECONDS="$DEFAULT_STAGGER_SECONDS"
TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

REPO_ROOT=""
WORK_PREFIX=""
SNAPSHOT_SHA=""
BASE_HEAD=""
PORCELAIN_LINES=0
PATCH_SHA256=""
PROMPT_TEXT=""
CHILD_PID=""
OK_COUNT=0
FAIL_COUNT=0
SCRUB_PENDING_COUNT=0
RESCRUB=false
RUN_STATUS=""
SCRUB_SED_ARGS=()

err() { echo "run-skill-comparison: ERROR: $*" >&2; }

usage() {
  cat <<'USAGE'
run-skill-comparison.sh — A/B skill-body comparison runner (headless claude -p)

Usage:
  run-skill-comparison.sh --prompt-file <f> --patch <f> --model <alias>
                          --trials <n> --label <fixture> --out <dir>
                          [--dry-run] [--keep-worktrees]
                          [--stagger-seconds <n>] [--timeout-seconds <n>]
                          [--help]
  run-skill-comparison.sh --rescrub --out <dir>

Required:
  --prompt-file <f>      Fixture prompt, passed verbatim to both arms.
  --patch <f>            Relaxation patch; applied uncommitted in arm B only.
  --model <alias>        Model alias for claude --model (e.g. fable, opus).
  --trials <n>           Trials per arm (A/B pairs run back-to-back).
  --label <fixture>      Fixture label embedded in run ids and the ledger.
  --out <dir>            Output dir; per-run subdirs + results.md land here.

Optional:
  --dry-run              Use the internal stub claude (no network), zero
                         stagger, full plumbing otherwise.
  --keep-worktrees       Skip teardown; prints the kept tmpdir prefix.
  --stagger-seconds <n>  Sleep between A/B pairs (default 45; dry-run 0).
  --timeout-seconds <n>  Per-run timeout (default 1800).
  --rescrub              Re-apply scrub rules to every run dir under --out and
                         flip SCRUB-PENDING runs whose files now pass.
                         Idempotent; only --out is required.
  --help                 This text.

Env:
  CLAUDE_BIN             claude binary override (tests point at a stub).

Behavior notes:
  - Snapshot is a temp-index commit of the live working tree (real index and
    branch untouched); arms are detached worktrees off that SHA.
  - The snapshot SHA is dangling and gc-reapable — recorded in meta.json as
    provenance only, never retrievable later.
  - total_cost_usd is an API-equivalent ESTIMATE on subscription auth, not
    billed dollars — recorded per run as a covariate, never a stop condition.
    Paid-draw protection is the billing_error hard-fail (usage credits OFF
    blocks paid runs); meter movement is verified manually per batch.
  - Transcripts/meta/stderr are scrubbed of machine paths before landing.
    A surviving machine path marks the run SCRUB-PENDING (data kept, batch
    continues, exit 3) — completed runs are valid experimental data and a
    scrub gap is a rules problem, not a run problem. Fix the rules, then
    --rescrub; never stage a SCRUB-PENDING run dir.
  - Failures retry once ONLY for transport-class errors (rate_limit,
    overloaded, server_error, connection); policy/billing/invalid_request
    hard-fail as FAILED-INFRA with no retry.

Exit codes:
  0  all runs OK (or rescrub: all dirs clean)
  1  any run failed or shared refs were mutated
  2  usage error
  3  runs OK but scrub-pending dirs present (or rescrub: still pending)
USAGE
}

require_tools() {
  local tool
  for tool in git jq sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      err "required tool not found: $tool"
      exit 2
    fi
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt-file)
        PROMPT_FILE="${2:-}"
        shift 2
        ;;
      --patch)
        PATCH_FILE="${2:-}"
        shift 2
        ;;
      --model)
        MODEL="${2:-}"
        shift 2
        ;;
      --trials)
        TRIALS="${2:-}"
        shift 2
        ;;
      --label)
        LABEL="${2:-}"
        shift 2
        ;;
      --out)
        OUT_DIR="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --rescrub)
        RESCRUB=true
        shift
        ;;
      --keep-worktrees)
        KEEP_WORKTREES=true
        shift
        ;;
      --stagger-seconds)
        STAGGER_SECONDS="${2:-}"
        shift 2
        ;;
      --timeout-seconds)
        TIMEOUT_SECONDS="${2:-}"
        shift 2
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ "$RESCRUB" == "true" ]]; then
    if [[ -z "$OUT_DIR" ]]; then
      err "--rescrub requires --out <dir>"
      exit 2
    fi
    if [[ ! -d "$OUT_DIR" ]]; then
      err "out dir not found: $OUT_DIR"
      exit 2
    fi
    OUT_DIR="$(cd "$OUT_DIR" && pwd)"
    return 0
  fi

  local missing=()
  [[ -n "$PROMPT_FILE" ]] || missing+=(--prompt-file)
  [[ -n "$PATCH_FILE" ]] || missing+=(--patch)
  [[ -n "$MODEL" ]] || missing+=(--model)
  [[ -n "$TRIALS" ]] || missing+=(--trials)
  [[ -n "$LABEL" ]] || missing+=(--label)
  [[ -n "$OUT_DIR" ]] || missing+=(--out)
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "missing required arguments: ${missing[*]}"
    usage >&2
    exit 2
  fi
  if [[ ! -f "$PROMPT_FILE" ]]; then
    err "prompt file not found: $PROMPT_FILE"
    exit 2
  fi
  if [[ ! -f "$PATCH_FILE" ]]; then
    err "patch file not found: $PATCH_FILE"
    exit 2
  fi
  if [[ ! "$TRIALS" =~ ^[1-9][0-9]*$ ]]; then
    err "--trials must be a positive integer, got: $TRIALS"
    exit 2
  fi
  if [[ ! "$STAGGER_SECONDS" =~ ^[0-9]+$ ]]; then
    err "--stagger-seconds must be a non-negative integer, got: $STAGGER_SECONDS"
    exit 2
  fi
  if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    err "--timeout-seconds must be a positive integer, got: $TIMEOUT_SECONDS"
    exit 2
  fi

  # Resolve inputs to absolute paths — runs spawn with cwd inside the arms.
  PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
  PATCH_FILE="$(cd "$(dirname "$PATCH_FILE")" && pwd)/$(basename "$PATCH_FILE")"
  mkdir -p "$OUT_DIR"
  OUT_DIR="$(cd "$OUT_DIR" && pwd)"

  if [[ "$DRY_RUN" == "true" ]]; then
    STAGGER_SECONDS=0
  fi
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
  PATCH_SHA256="$(sha256sum "$PATCH_FILE" | awk '{print $1}')"
}

refs_digest() {
  git -C "$REPO_ROOT" for-each-ref --format='%(refname)%(objectname)' \
    | sha256sum | awk '{print $1}'
}

# Remove ONE worktree registration, path-scoped. Falls back to removing the
# matching admin dir under <common-dir>/worktrees/ when the working tree
# directory is already gone (git worktree remove can refuse a missing dir;
# global prune is forbidden — it would unregister concurrent sessions' trees).
remove_worktree_registration() {
  local wt_path="$1"
  if git -C "$REPO_ROOT" worktree remove --force "$wt_path" >/dev/null 2>&1; then
    return 0
  fi
  local common admin gitdir_file recorded
  common="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
  for admin in "$common"/worktrees/*/; do
    [[ -d "$admin" ]] || continue
    gitdir_file="$admin/gitdir"
    [[ -f "$gitdir_file" ]] || continue
    recorded="$(tr -d '\r' <"$gitdir_file")"
    if [[ "$recorded" == "$wt_path/.git" || "$recorded" == "$wt_path"/* ]]; then
      rm -rf "$admin"
    fi
  done
}

# Self-heal after a prior interrupted run: drop registrations whose path
# matches OUR prefix name AND whose directory no longer exists. Never touches
# other tools' worktrees, never prunes globally.
reconcile_stale_worktrees() {
  local wt_path
  while IFS= read -r wt_path; do
    case "$wt_path" in
      */"$WORKTREE_PREFIX_NAME".*)
        if [[ ! -d "$wt_path" ]]; then
          echo "reconciler: removing stale worktree registration: $wt_path" >&2
          remove_worktree_registration "$wt_path"
        fi
        ;;
      *) ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain | sed -n 's/^worktree //p')
}

# Temp-index snapshot of the live working tree: real index/staging untouched,
# no stash, branch never moves. GIT_INDEX_FILE is a per-command env prefix,
# NEVER exported.
snapshot_live_tree() {
  BASE_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  PORCELAIN_LINES="$(git -C "$REPO_ROOT" status --porcelain | wc -l | tr -d ' \r')"
  local tmp_index tree
  tmp_index="$(mktemp "${TMPDIR:-/tmp}/skill-comparison-index.XXXXXX")"
  GIT_INDEX_FILE="$tmp_index" git -C "$REPO_ROOT" read-tree HEAD
  GIT_INDEX_FILE="$tmp_index" git -C "$REPO_ROOT" add -A
  tree="$(GIT_INDEX_FILE="$tmp_index" git -C "$REPO_ROOT" write-tree)"
  SNAPSHOT_SHA="$(git -C "$REPO_ROOT" -c user.name=skill-comparison \
    -c user.email=skill-comparison@invalid \
    commit-tree "$tree" -p "$BASE_HEAD" \
    -m "ephemeral live-tree snapshot (dangling; gc-reapable)")"
  rm -f "$tmp_index"
}

create_arms() {
  WORK_PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/$WORKTREE_PREFIX_NAME.XXXXXX")"
  git -C "$REPO_ROOT" worktree add --detach --quiet "$WORK_PREFIX/arm-a" "$SNAPSHOT_SHA"
  git -C "$REPO_ROOT" worktree add --detach --quiet "$WORK_PREFIX/arm-b" "$SNAPSHOT_SHA"
}

# Restore an arm to pristine snapshot state between runs; re-apply the
# relaxation patch for arm B (local + uncommitted by design — it never lands
# on any branch).
reset_arm() {
  local arm_name="$1" arm_path="$2"
  git -C "$arm_path" reset --hard --quiet "$SNAPSHOT_SHA"
  git -C "$arm_path" clean -fdx --quiet
  if [[ "$arm_name" == "b" ]]; then
    git -C "$arm_path" apply "$PATCH_FILE"
  fi
}

write_internal_stub() {
  local stub_path="$WORK_PREFIX/stub-claude.sh"
  cat >"$stub_path" <<'STUB'
#!/usr/bin/env bash
# Internal dry-run stub: emits minimal valid claude stream-json — system/init
# carrying the requested model + mcp_servers + cwd, then a zero-cost result.
set -euo pipefail
model="unknown"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--model" ]]; then
    model="$arg"
  fi
  prev="$arg"
done
printf '{"type":"system","subtype":"init","model":"claude-%s-stub","mcp_servers":[{"name":"stub","status":"connected"}],"cwd":"%s"}\n' "$model" "$PWD"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"stub run in %s"}]}}\n' "$PWD"
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0}\n'
STUB
  chmod +x "$stub_path"
  CLAUDE_BIN="$stub_path"
}

# --- Scrub machinery ---------------------------------------------------------

# Escape a literal string for use as a sed BRE pattern with `|` delimiter.
sed_escape_pattern() {
  printf '%s' "$1" | sed -e 's/[][\\.*^$|]/\\&/g'
}

# Emit unique textual forms of a path (posix, Windows backslash, Windows
# forward-slash, JSON-escaped double-backslash), one per line.
path_forms() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  local -a forms=("$p")
  if command -v cygpath >/dev/null 2>&1; then
    # Both short (8.3, e.g. <user>~1) and long (-l) Windows forms — transcripts
    # can carry either depending on which env var the child process expanded.
    forms+=("$(cygpath -w "$p" 2>/dev/null || true)")
    forms+=("$(cygpath -lw "$p" 2>/dev/null || true)")
    forms+=("$(cygpath -m "$p" 2>/dev/null || true)")
    forms+=("$(cygpath -lm "$p" 2>/dev/null || true)")
    forms+=("$(cygpath -u "$p" 2>/dev/null || true)")
  fi
  local form
  for form in "${forms[@]}"; do
    [[ -n "$form" ]] || continue
    printf '%s\n' "$form"
    if [[ "$form" == *\\* ]]; then
      printf '%s\n' "${form//\\/\\\\}"
    fi
  done | awk '!seen[$0]++'
}

add_scrub() {
  local raw="$1" replacement="$2" form
  [[ -n "$raw" ]] || return 0
  while IFS= read -r form; do
    [[ -n "$form" ]] || continue
    SCRUB_SED_ARGS+=(-e "s|$(sed_escape_pattern "$form")|$replacement|g")
  done < <(path_forms "$raw")
}

# Order matters: the arm tmpdir prefix sits under the user's temp dir, which
# sits under the home dir on Windows — scrub the most specific path first.
build_scrub_table() {
  add_scrub "$WORK_PREFIX" "<ARM>"
  add_scrub "$REPO_HUB_DIR" "<REPO-HUB>"
  add_scrub "${HOME:-}" "<HOME>"
  add_scrub "${USERPROFILE:-}" "<HOME>"
  local user_name="${USERNAME:-${USER:-}}"
  if [[ -n "$user_name" ]]; then
    SCRUB_SED_ARGS+=(-e "s|$(sed_escape_pattern "$user_name")|<USER>|g")
  fi
  # Async-agent tool results (Agent tool inside a -p run) embed harness temp
  # paths in two shapes the literal-$HOME rules miss: the 8.3 short-form home
  # (C:\Users\<user>~1\...) and CC's cwd-slug encoding of the arm tmpdir
  # (C--Users-<USER>-AppData-Local-Temp-skill-comparison-XXXXXX-arm-a — every
  # separator flattened to '-'). Generic user-dir forms first (doubled
  # backslash, single backslash, drive-slash, git-bash slash), then the slug
  # shapes. The username rule above runs first, so slugs may already carry
  # <USER> — the char class includes <>.
  SCRUB_SED_ARGS+=(
    -e 's|[A-Za-z]:\\\\Users\\\\[A-Za-z0-9~._<>-]*|<HOME>|g'
    -e 's|[A-Za-z]:\\Users\\[A-Za-z0-9~._<>-]*|<HOME>|g'
    -e 's|[A-Za-z]:/Users/[A-Za-z0-9~._<>-]*|<HOME>|g'
    -e 's|/[A-Za-z]/Users/[A-Za-z0-9~._<>-]*|<HOME>|g'
    -e 's|[A-Za-z]--Users-[A-Za-z0-9~._<>-]*-arm-a|<ARM-SLUG-A>|g'
    -e 's|[A-Za-z]--Users-[A-Za-z0-9~._<>-]*-arm-b|<ARM-SLUG-B>|g'
  )
  # Model/agent output also reformats paths in shapes no literal rule can
  # anticipate: a subagent's bash can eat backslashes wholesale
  # (C:UsersNameAppDataLocalTempskill-comparison.XXXXXXarm-b...), and prose
  # abbreviates roots with an ellipsis (C:\...\Directory.Build.props) whose
  # bare drive prefix trips the forbidden gate. Collapse both generically.
  SCRUB_SED_ARGS+=(
    -e 's|[A-Za-z]:Users[A-Za-z0-9~._<>-]*|<PATH-NOSEP>|g'
    -e 's|[A-Za-z]:\\\\\.\.\.|<PATH>|g'
    -e 's|[A-Za-z]:\\\.\.\.|<PATH>|g'
    -e 's|[A-Za-z]:/\.\.\.|<PATH>|g'
  )
  # Hook output (e.g. SessionStart MSBuild cache notes) references paths under
  # the home dir; after the <HOME> scrub the bare "AppData" remainder would
  # trip the forbidden gate, so collapse the well-known Windows dirs. Doubled
  # backslash forms first (JSON-escaped transcripts), then single, then slash.
  SCRUB_SED_ARGS+=(
    -e 's|<HOME>\\\\AppData\\\\Local|<LOCALAPPDATA>|g'
    -e 's|<HOME>\\\\AppData\\\\Roaming|<APPDATA>|g'
    -e 's|<HOME>\\AppData\\Local|<LOCALAPPDATA>|g'
    -e 's|<HOME>\\AppData\\Roaming|<APPDATA>|g'
    -e 's|<HOME>/AppData/Local|<LOCALAPPDATA>|g'
    -e 's|<HOME>/AppData/Roaming|<APPDATA>|g'
  )
  # task_progress description fields truncate commands mid-path (Unicode
  # ellipsis right after "AppData\"), so the Local/Roaming collapse above can
  # never fire on them. Collapse the truncated home-anchored form, then as a
  # final belt rewrite ANY residual AppData token — by this point every
  # identifying prefix (home, user, arm, slug, stripped) is already
  # anonymized, so a leftover token is context-free and the placeholder
  # carries the same information without tripping the forbidden gate.
  SCRUB_SED_ARGS+=(
    -e 's|<HOME>\\\\AppData|<HOME-APPDIR>|g'
    -e 's|<HOME>\\AppData|<HOME-APPDIR>|g'
    -e 's|<HOME>/AppData|<HOME-APPDIR>|g'
    -e 's|AppData|<APPDIR>|g'
  )
  # Same belt for the remaining forbidden-gate tokens: a novel reformatting
  # should rewrite to a placeholder, not abort a multi-run batch. /Users/<name>
  # eats the username segment (token-only rewrite would leave the name behind);
  # the C-drive rule targets the doubled JSON-escaped form the gate checks.
  SCRUB_SED_ARGS+=(
    -e 's|/Users/[A-Za-z0-9~._<>-]*|<HOME>|g'
    -e 's|C:\\\\|<C-DRIVE>\\\\|g'
    -e 's|/tmp/tmp\.|/tmp/<TMPDIR>.|g'
  )
}

scrub_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ ${#SCRUB_SED_ARGS[@]} -gt 0 ]] || return 0
  sed -i "${SCRUB_SED_ARGS[@]}" "$f"
}

# Non-fatal: a run whose transcript carries a not-yet-covered path shape is
# valid experimental data — it must never abort the batch or be deleted. The
# run is marked SCRUB-PENDING; fix the rules, then `--rescrub` re-applies them
# idempotently and flips the status. Pending dirs must not be staged.
scrub_clean() {
  local f failed=0
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if grep -qE "$SCRUB_FORBIDDEN_REGEX" "$f"; then
      err "scrub check: machine path survives in $f:"
      grep -nE "$SCRUB_FORBIDDEN_REGEX" "$f" | head -5 >&2
      failed=1
    fi
  done
  return "$failed"
}

# Re-apply the (since-fixed) scrub rules to every run dir under --out and flip
# SCRUB-PENDING runs whose files now pass. Idempotent — placeholders never
# re-match the rules. WORK_PREFIX no longer exists at rescrub time; its
# literal rules were already applied at capture, and the generic shape rules
# carry the rest.
rescrub_out_dir() {
  build_scrub_table
  local dir f run_id meta_tmp fixed=0 pending=0
  for dir in "$OUT_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    for f in "${dir}transcript.jsonl" "${dir}stderr.log" "${dir}meta.json"; do
      [[ -f "$f" ]] || continue
      scrub_file "$f"
    done
    # scrub_clean is a status predicate; conditional use is the contract.
    # shellcheck disable=SC2310
    if scrub_clean "${dir}transcript.jsonl" "${dir}stderr.log" "${dir}meta.json"; then
      if [[ -f "${dir}meta.json" ]] \
        && [[ "$(jq -r '.status // empty' "${dir}meta.json")" == "SCRUB-PENDING" ]]; then
        meta_tmp="$(mktemp)"
        jq '.status = "OK" | .scrub = "clean"' "${dir}meta.json" >"$meta_tmp" \
          && mv "$meta_tmp" "${dir}meta.json"
        run_id="$(jq -r .run_id "${dir}meta.json")"
        if [[ -f "$OUT_DIR/results.md" ]]; then
          sed -i "/^| ${run_id} /s/| SCRUB-PENDING |/| OK |/" "$OUT_DIR/results.md"
        fi
        fixed=$((fixed + 1))
        echo "rescrub: $run_id clean — status flipped to OK" >&2
      fi
    else
      pending=$((pending + 1))
      err "rescrub: $(basename "$dir") still pending"
    fi
  done
  echo "rescrub complete: $fixed flipped to OK, $pending still pending" >&2
  [[ "$pending" -eq 0 ]] || exit 3
  exit 0
}

# --- Run execution -----------------------------------------------------------

ensure_ledger() {
  local ledger="$OUT_DIR/results.md"
  if [[ ! -f "$ledger" ]]; then
    {
      printf '# Comparison run ledger\n\n'
      printf '| run_id | label | arm | model | trial | attempt | status | model_actual | total_cost_usd | graded | notes |\n'
      printf '|---|---|---|---|---|---|---|---|---|---|---|\n'
    } >"$ledger"
  fi
}

append_ledger() {
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |  | %s |\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" >>"$OUT_DIR/results.md"
}

# Run one attempt for one arm/trial. Sets RUN_STATUS to OK | RETRYABLE |
# FAILED-INFRA. Writes run dir, scrubs, appends ledger.
run_attempt() {
  local arm_name="$1" arm_path="$2" trial="$3" attempt="$4"
  local ts run_id run_dir
  ts="$(date -u +%Y%m%dT%H%M%S)Z"
  run_id="${ts}-${LABEL}-${arm_name}-${MODEL}-t${trial}"
  if [[ "$attempt" -gt 1 ]]; then
    run_id="${run_id}-attempt${attempt}"
  fi
  run_dir="$OUT_DIR/$run_id"
  mkdir -p "$run_dir"
  local transcript="$run_dir/transcript.jsonl"
  local stderr_log="$run_dir/stderr.log"
  local meta="$run_dir/meta.json"

  local -a cmd=()
  if command -v timeout >/dev/null 2>&1; then
    cmd+=(timeout -k 15 "$TIMEOUT_SECONDS")
  fi
  cmd+=("$CLAUDE_BIN" -p "$PROMPT_TEXT" --model "$MODEL"
    --output-format stream-json --verbose
    --permission-mode bypassPermissions --no-session-persistence
    --settings "$SETTINGS_OVERRIDE_JSON")

  local rc=0
  (
    cd "$arm_path" || exit 97
    # settings.local.json is NOT in the snapshot — export the stream-watchdog
    # envelope per run (long Opus thinking pauses exceed the 90s default).
    # CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0: a claude -p spawned from inside a
    # CC session inherits the env-scrub hardening, which silently forces
    # permission mode to default and would contaminate fixture runs with tool
    # denials; arms are isolated detached worktrees + refs-digest guarded.
    exec env CLAUDE_STREAM_IDLE_TIMEOUT_MS="$STREAM_IDLE_TIMEOUT_MS" \
      CLAUDE_ENABLE_STREAM_WATCHDOG=1 \
      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 "${cmd[@]}"
  ) >"$transcript" 2>"$stderr_log" &
  CHILD_PID=$!
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""

  local model_actual mcp_servers cost
  model_actual="$(jq -rR 'fromjson? | select(.type=="system" and .subtype=="init") | .model // empty' "$transcript" 2>/dev/null | head -1)" || true
  mcp_servers="$(jq -cR 'fromjson? | select(.type=="system" and .subtype=="init") | .mcp_servers // []' "$transcript" 2>/dev/null | head -1)" || true
  [[ -n "$mcp_servers" ]] || mcp_servers='[]'
  cost="$(jq -rR 'fromjson? | select(.type=="result") | (.total_cost_usd // 0) | tostring' "$transcript" 2>/dev/null | tail -1)" || true

  local status="OK" note=""
  if [[ "$rc" -ne 0 || -z "$cost" ]]; then
    if grep -qiE 'usage policy|invalid_request|billing' "$transcript" "$stderr_log" 2>/dev/null; then
      status="FAILED-INFRA"
      note="hard-fail (policy/billing/invalid_request, exit $rc); no retry"
    elif grep -qiE 'rate.?limit|overloaded|server_error|api_retry|connection|econnreset|etimedout|socket' "$transcript" "$stderr_log" 2>/dev/null; then
      if [[ "$attempt" -ge 2 ]]; then
        status="FAILED-INFRA"
        note="transport-class failure persisted after retry (exit $rc)"
      else
        status="RETRYABLE"
        note="transport-class failure (exit $rc); retrying once"
      fi
    else
      status="FAILED-INFRA"
      note="unclassified failure (exit $rc); no retry"
    fi
  elif [[ -z "$model_actual" || "$model_actual" != *"$MODEL"* ]]; then
    status="FAILED-INFRA"
    note="model mismatch: requested $MODEL got ${model_actual:-none} (sticky classifier reroute?); trial not counted"
  fi

  # total_cost_usd on subscription auth is an API-equivalent estimate, not
  # billed dollars — record as covariate; actual paid-draw protection is the
  # billing_error hard-fail above (usage credits OFF blocks paid runs).
  if [[ "$status" == "OK" && "$MODEL" == *fable* && -z "$note" ]]; then
    if awk -v c="${cost:-0}" 'BEGIN { exit (c + 0 > 0) ? 0 : 1 }'; then
      note="total_cost_usd $cost is a subscription estimate (covariate, not billed); verify meters per batch"
    fi
  fi

  scrub_file "$transcript"
  scrub_file "$stderr_log"
  local scrub_state="clean"
  # scrub_clean is a status predicate; conditional use is the contract.
  # shellcheck disable=SC2310
  if ! scrub_clean "$transcript" "$stderr_log"; then
    scrub_state="pending"
    if [[ "$status" == "OK" ]]; then
      status="SCRUB-PENDING"
      note="${note:+$note; }machine path survives post-scrub — data KEPT, do not stage; fix rules then run --rescrub"
    else
      note="${note:+$note; }scrub pending"
    fi
  fi

  jq -n \
    --arg arm "$arm_name" \
    --argjson attempt "$attempt" \
    --arg base_head_sha "$BASE_HEAD" \
    --argjson claude_exit_code "$rc" \
    --arg label "$LABEL" \
    --argjson mcp_servers "$mcp_servers" \
    --arg model_actual "${model_actual:-}" \
    --arg model_requested "$MODEL" \
    --arg note "$note" \
    --arg patch_sha256 "$PATCH_SHA256" \
    --argjson porcelain_lines "$PORCELAIN_LINES" \
    --arg run_id "$run_id" \
    --arg scrub "$scrub_state" \
    --arg snapshot_sha_dangling_nonretrievable "$SNAPSHOT_SHA" \
    --arg status "$status" \
    --arg timestamp_utc "$ts" \
    --arg total_cost_usd "${cost:-}" \
    --argjson trial "$trial" \
    '$ARGS.named' >"$meta"

  scrub_file "$meta"
  # scrub_clean is a status predicate; conditional use is the contract.
  # shellcheck disable=SC2310
  if ! scrub_clean "$meta"; then
    scrub_state="pending"
    status="SCRUB-PENDING"
    local meta_tmp
    meta_tmp="$(mktemp)"
    jq '.status = "SCRUB-PENDING" | .scrub = "pending"' "$meta" >"$meta_tmp" && mv "$meta_tmp" "$meta"
  fi

  ensure_ledger
  append_ledger "$run_id" "$LABEL" "$arm_name" "$MODEL" "$trial" "$attempt" \
    "$status" "${model_actual:-none}" "${cost:-n/a}" "$note"

  echo "run $run_id: $status${note:+ — $note}" >&2

  RUN_STATUS="$status"
}

run_with_retry() {
  local arm_name="$1" arm_path="$2" trial="$3"
  reset_arm "$arm_name" "$arm_path"
  run_attempt "$arm_name" "$arm_path" "$trial" 1
  if [[ "$RUN_STATUS" == "RETRYABLE" ]]; then
    reset_arm "$arm_name" "$arm_path"
    run_attempt "$arm_name" "$arm_path" "$trial" 2
  fi
  if [[ "$RUN_STATUS" == "OK" ]]; then
    OK_COUNT=$((OK_COUNT + 1))
  elif [[ "$RUN_STATUS" == "SCRUB-PENDING" ]]; then
    SCRUB_PENDING_COUNT=$((SCRUB_PENDING_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Teardown ----------------------------------------------------------------

cleanup_worktrees() {
  if [[ -n "${CHILD_PID:-}" ]]; then
    kill "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""
  fi
  [[ -n "${WORK_PREFIX:-}" && -n "${REPO_ROOT:-}" ]] || return 0
  if [[ "$KEEP_WORKTREES" == "true" ]]; then
    echo "kept worktrees under: $WORK_PREFIX" >&2
    return 0
  fi
  local arm
  for arm in "$WORK_PREFIX/arm-a" "$WORK_PREFIX/arm-b"; do
    if [[ -d "$arm" ]]; then
      remove_worktree_registration "$arm"
    fi
  done
  rm -rf "$WORK_PREFIX" 2>/dev/null || true
  WORK_PREFIX=""
}

on_signal() {
  trap - EXIT INT TERM HUP
  err "interrupted — tearing down worktrees"
  cleanup_worktrees
  exit 130
}

main() {
  parse_args "$@"
  require_tools
  if [[ "$RESCRUB" == "true" ]]; then
    rescrub_out_dir
  fi

  REPO_ROOT="$(git rev-parse --show-toplevel | tr -d '\r')" || {
    err "not inside a git repository"
    exit 2
  }

  trap on_signal INT TERM HUP
  trap cleanup_worktrees EXIT

  local refs_before refs_after
  refs_before="$(refs_digest)"

  reconcile_stale_worktrees
  snapshot_live_tree
  create_arms
  build_scrub_table

  if [[ "$DRY_RUN" == "true" ]]; then
    write_internal_stub
  fi

  local trial
  for ((trial = 1; trial <= TRIALS; trial++)); do
    if [[ "$trial" -gt 1 && "$STAGGER_SECONDS" -gt 0 ]]; then
      echo "staggering ${STAGGER_SECONDS}s before pair $trial" >&2
      sleep "$STAGGER_SECONDS"
    fi
    # A/B pairs back-to-back to minimize web-state drift inside a pair.
    run_with_retry "a" "$WORK_PREFIX/arm-a" "$trial"
    run_with_retry "b" "$WORK_PREFIX/arm-b" "$trial"
  done

  refs_after="$(refs_digest)"
  if [[ "$refs_before" != "$refs_after" ]]; then
    err "shared refs digest changed during the batch — a run mutated the shared git store; inspect before trusting results"
    exit 1
  fi

  echo "batch complete: $OK_COUNT OK, $SCRUB_PENDING_COUNT scrub-pending, $FAIL_COUNT failed (ledger: $OUT_DIR/results.md)" >&2
  [[ "$FAIL_COUNT" -eq 0 ]] || exit 1
  if [[ "$SCRUB_PENDING_COUNT" -gt 0 ]]; then
    err "scrub-pending runs present — data kept; fix scrub rules, then: $0 --rescrub --out $OUT_DIR"
    exit 3
  fi
}

main "$@"
