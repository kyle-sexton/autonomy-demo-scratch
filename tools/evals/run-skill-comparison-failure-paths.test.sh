#!/usr/bin/env bash
# Failure-paths shard for run-skill-comparison.sh: TERM-interrupt teardown
# (full-signal trap) and cost-as-covariate recording (subscription estimate,
# never a stop). Helpers/sibling shards documented in
# run-skill-comparison-test-helpers.sh.
set -uo pipefail

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
FAILED=0
CASE_NUM=0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-skill-comparison-test-helpers.sh"

PROMPT_FILE="$TEST_TMPDIR/prompt.txt"
make_prompt "$PROMPT_FILE"

# --- Case: interrupt (TERM) tears worktrees down via the signal trap ---

F4="$TEST_TMPDIR/f4"
make_fixture "$F4"
PATCH4="$TEST_TMPDIR/relax4.patch"
make_patch "$F4" "$PATCH4"
SLEEP_STUB="$TEST_TMPDIR/sleep-stub.sh"
cat >"$SLEEP_STUB" <<'EOF'
#!/usr/bin/env bash
# Slow stub: short sleeps so an orphaned child frees its cwd within ~0.1s.
trap 'exit 0' TERM
for _ in $(seq 1 300); do sleep 0.1; done
EOF
chmod +x "$SLEEP_STUB"
mkdir -p "$TEST_TMPDIR/wt4"

(
  cd "$F4" \
    && exec env TMPDIR="$TEST_TMPDIR/wt4" CLAUDE_BIN="$SLEEP_STUB" \
      bash "$DRIVER" --prompt-file "$PROMPT_FILE" --patch "$PATCH4" \
      --model fable --trials 1 --label intr --out "$TEST_TMPDIR/out4" \
      --stagger-seconds 0
) >/dev/null 2>&1 &
DRIVER_PID=$!

APPEARED=false
for _ in $(seq 1 75); do
  if git -C "$F4" worktree list | grep -q "skill-comparison"; then
    APPEARED=true
    break
  fi
  sleep 0.2
done
if [[ "$APPEARED" == "true" ]]; then
  pass "interrupt case: worktrees appeared mid-run"
else
  fail "interrupt case: worktrees appeared mid-run" "skill-comparison in worktree list" "absent after 15s"
fi

kill -TERM "$DRIVER_PID" 2>/dev/null
wait "$DRIVER_PID" 2>/dev/null || true

GONE=false
for _ in $(seq 1 50); do
  if ! git -C "$F4" worktree list | grep -q "skill-comparison"; then
    GONE=true
    break
  fi
  sleep 0.2
done
if [[ "$GONE" == "true" ]]; then
  pass "interrupt cleanup: worktree registrations removed"
else
  fail "interrupt cleanup: worktree registrations removed" "no skill-comparison entries" "$(git -C "$F4" worktree list)"
fi
LEFTOVER="$(find "$TEST_TMPDIR/wt4" -mindepth 1 -maxdepth 1 -name 'skill-comparison.*' 2>/dev/null | wc -l | tr -d ' \r')"
assert_eq "interrupt cleanup: tmpdir prefix removed" "0" "$LEFTOVER"

# --- Case: nonzero cost on a fable run is a recorded covariate, not a stop ---
# total_cost_usd on subscription auth is an API-equivalent estimate; the batch
# completes, meta/ledger record the value, and the note flags it for the
# manual per-batch meter check.

F5="$TEST_TMPDIR/f5"
make_fixture "$F5"
PATCH5="$TEST_TMPDIR/relax5.patch"
make_patch "$F5" "$PATCH5"
COST_STUB="$TEST_TMPDIR/cost-stub.sh"
cat >"$COST_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
model="unknown"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--model" ]]; then
    model="$arg"
  fi
  prev="$arg"
done
printf '{"type":"system","subtype":"init","model":"claude-%s-stub","mcp_servers":[]}\n' "$model"
printf '{"type":"system","subtype":"hook_progress","stdout":"Cache: %s/AppData/Local/medley/msbuild-meta-12345.json"}\n' "$HOME"
printf '{"type":"user","text":"output_file: C:\\\\Users\\\\SHORTN~1\\\\AppData\\\\Local\\\\Temp\\\\claude\\\\C--Users-TestUser-AppData-Local-Temp-skill-comparison-XyZ123-arm-a\\\\tasks\\\\a1.output"}\n'
printf '{"type":"user","text":"ls: cannot access C:UsersTestUserAppDataLocalTempskill-comparison.Xy12arm-bapps: No such file"}\n'
printf '{"type":"assistant","text":"**File:** C:\\\\...\\\\Directory.Build.props and C:\\...\\global.json and C:/.../README.md"}\n'
printf '{"type":"system","subtype":"task_progress","description":"Running Get-ChildItem -Path \\"%s/AppData/…"}\n' "$HOME"
printf '{"type":"user","text":"stray AppDataRoamingThing token from an unforeseen truncation"}\n'
printf '{"type":"user","text":"macOS /Users/<user>/repo path, doubled C:\\\\Windows\\\\System32 drive, /tmp/tmp.AbC12 mktemp"}\n'
hub="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
hub="${hub%/*}"
printf '{"type":"user","text":"git worktree list: %s/.bare (bare) and %s/main [main] detached"}\n' "$hub" "$hub"
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.42}\n'
EOF
chmod +x "$COST_STUB"
mkdir -p "$TEST_TMPDIR/wt5"

OUT=$(
  cd "$F5" && TMPDIR="$TEST_TMPDIR/wt5" CLAUDE_BIN="$COST_STUB" \
    bash "$DRIVER" --prompt-file "$PROMPT_FILE" --patch "$PATCH5" \
    --model fable --trials 1 --label cost --out "$TEST_TMPDIR/out5" \
    --stagger-seconds 0 2>&1
)
RC=$?
assert_exit "nonzero-cost fable batch completes with exit 0" 0 "$RC"
assert_not_contains "no cost STOP status is emitted" "$OUT" "FAILED-COST-GATE"
COST_RUN_COUNT="$(find "$TEST_TMPDIR/out5" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' \r')"
assert_eq "both arms ran to completion" "2" "$COST_RUN_COUNT"
COST_META="$(find "$TEST_TMPDIR/out5" -name meta.json | sort | head -1)"
assert_eq "meta records the estimate cost" "0.42" "$(jq -r .total_cost_usd "$COST_META")"
assert_contains "meta note flags cost as covariate" "$(jq -r .note "$COST_META")" "covariate"
COST_TRANSCRIPT="$(find "$TEST_TMPDIR/out5" -name transcript.jsonl | sort | head -1)"
assert_contains "home-dir AppData path collapses to <LOCALAPPDATA>" "$(cat "$COST_TRANSCRIPT")" "<LOCALAPPDATA>/medley/msbuild-meta-12345.json"
assert_contains "8.3 short-form home collapses via generic user-dir rule" "$(cat "$COST_TRANSCRIPT")" "<LOCALAPPDATA>\\\\Temp\\\\claude"
assert_contains "cwd-slug arm path collapses to <ARM-SLUG-A>" "$(cat "$COST_TRANSCRIPT")" "<ARM-SLUG-A>"
assert_not_contains "no slug-encoded Users segment survives" "$(cat "$COST_TRANSCRIPT")" "--Users-"
assert_contains "separator-stripped path collapses to <PATH-NOSEP>" "$(cat "$COST_TRANSCRIPT")" "<PATH-NOSEP>"
assert_contains "ellipsis-abbreviated root collapses to <PATH>" "$(cat "$COST_TRANSCRIPT")" "<PATH>\\\\Directory.Build.props"
assert_not_contains "no bare drive prefix survives" "$(cat "$COST_TRANSCRIPT")" "C:"
assert_contains "truncated home-anchored AppData collapses" "$(cat "$COST_TRANSCRIPT")" "<HOME-APPDIR>/…"
assert_contains "belt rewrites residual AppData tokens" "$(cat "$COST_TRANSCRIPT")" "<APPDIR>RoamingThing"
assert_contains "belt eats /Users/ username segment" "$(cat "$COST_TRANSCRIPT")" "macOS <HOME>/repo path"
assert_contains "belt rewrites doubled C-drive token" "$(cat "$COST_TRANSCRIPT")" "<C-DRIVE>\\\\Windows"
assert_contains "belt rewrites /tmp/tmp. mktemp token" "$(cat "$COST_TRANSCRIPT")" "/tmp/<TMPDIR>.AbC12"
assert_not_contains "no bare AppData survives the scrub" "$(cat "$COST_TRANSCRIPT")" "AppData"
assert_contains "repo hub path collapses to <REPO-HUB>" "$(cat "$COST_TRANSCRIPT")" "<REPO-HUB>/main"
assert_not_contains "no raw repo hub path survives" "$(cat "$COST_TRANSCRIPT")" "f5/.bare"
WT_LIST="$(git -C "$F5" worktree list)"
assert_not_contains "completed batch tears worktrees down" "$WT_LIST" "skill-comparison"

F6="$TEST_TMPDIR/f6"
make_fixture "$F6"
PATCH6="$TEST_TMPDIR/relax6.patch"
make_patch "$F6" "$PATCH6"
LEAK_STUB="$TEST_TMPDIR/leak-stub.sh"
cat >"$LEAK_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
model="unknown"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--model" ]]; then
    model="$arg"
  fi
  prev="$arg"
done
printf '{"type":"system","subtype":"init","model":"claude-%s-stub","mcp_servers":[]}\n' "$model"
printf '{"type":"user","text":"novel leak shape SENTINEL-LEAK no rule covers"}\n'
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1}\n'
EOF
chmod +x "$LEAK_STUB"
mkdir -p "$TEST_TMPDIR/wt6"

OUT=$(
  cd "$F6" && TMPDIR="$TEST_TMPDIR/wt6" CLAUDE_BIN="$LEAK_STUB" \
    SCRUB_FORBIDDEN_REGEX_OVERRIDE='SENTINEL-LEAK' \
    bash "$DRIVER" --prompt-file "$PROMPT_FILE" --patch "$PATCH6" \
    --model fable --trials 1 --label leak --out "$TEST_TMPDIR/out6" \
    --stagger-seconds 0 2>&1
)
RC=$?
assert_exit "uncovered leak shape exits 3 (pending), not 1" 3 "$RC"
assert_contains "batch continues past the pending run" "$OUT" "2 scrub-pending"
LEAK_RUN_COUNT="$(find "$TEST_TMPDIR/out6" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' \r')"
assert_eq "pending run dirs are KEPT, never deleted" "2" "$LEAK_RUN_COUNT"
LEAK_META="$(find "$TEST_TMPDIR/out6" -name meta.json | sort | head -1)"
assert_eq "meta records SCRUB-PENDING status" "SCRUB-PENDING" "$(jq -r .status "$LEAK_META")"
assert_eq "meta records scrub=pending" "pending" "$(jq -r .scrub "$LEAK_META")"
assert_contains "ledger row carries SCRUB-PENDING" "$(cat "$TEST_TMPDIR/out6/results.md")" "SCRUB-PENDING"

OUT=$(SCRUB_FORBIDDEN_REGEX_OVERRIDE='SENTINEL-LEAK' bash "$DRIVER" --rescrub --out "$TEST_TMPDIR/out6" 2>&1)
RC=$?
assert_exit "rescrub with unfixed rules stays pending (exit 3)" 3 "$RC"

OUT=$(bash "$DRIVER" --rescrub --out "$TEST_TMPDIR/out6" 2>&1)
RC=$?
assert_exit "rescrub after rules cover the shape exits 0" 0 "$RC"
assert_contains "rescrub flips both pending runs" "$OUT" "2 flipped to OK"
assert_eq "meta status flipped to OK" "OK" "$(jq -r .status "$LEAK_META")"
assert_eq "meta scrub flipped to clean" "clean" "$(jq -r .scrub "$LEAK_META")"
assert_not_contains "no SCRUB-PENDING ledger rows remain" "$(cat "$TEST_TMPDIR/out6/results.md")" "SCRUB-PENDING"

# --- Case: shared refs digest mutation fails the batch ---

F7="$TEST_TMPDIR/f7"
make_fixture "$F7"
PATCH7="$TEST_TMPDIR/relax7.patch"
make_patch "$F7" "$PATCH7"
POISON_STUB="$TEST_TMPDIR/poison-stub.sh"
cat >"$POISON_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git update-ref refs/heads/skill-comparison-poison HEAD >/dev/null 2>&1 || true
model="unknown"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--model" ]]; then
    model="$arg"
  fi
  prev="$arg"
done
printf '{"type":"system","subtype":"init","model":"claude-%s-stub","mcp_servers":[]}\n' "$model"
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0}\n'
EOF
chmod +x "$POISON_STUB"
mkdir -p "$TEST_TMPDIR/wt7"

OUT=$(
  cd "$F7" && TMPDIR="$TEST_TMPDIR/wt7" CLAUDE_BIN="$POISON_STUB" \
    bash "$DRIVER" --prompt-file "$PROMPT_FILE" --patch "$PATCH7" \
    --model fable --trials 1 --label poison --out "$TEST_TMPDIR/out7" \
    --stagger-seconds 0 2>&1
)
RC=$?
assert_exit "refs digest mutation exits 1" 1 "$RC"
assert_contains "refs digest mutation message" "$OUT" "shared refs digest changed"
git -C "$F7" update-ref -d refs/heads/skill-comparison-poison >/dev/null 2>&1 || true

# --- Case: RETRYABLE transport failure retries once then succeeds ---

F8="$TEST_TMPDIR/f8"
make_fixture "$F8"
PATCH8="$TEST_TMPDIR/relax8.patch"
make_patch "$F8" "$PATCH8"
RETRY_STUB="$TEST_TMPDIR/retry-stub.sh"
RETRY_COUNTER="$TEST_TMPDIR/retry-count"
printf '0' >"$RETRY_COUNTER"
cat >"$RETRY_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count_file="${RETRY_COUNTER_FILE:?}"
count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" >"$count_file"
model="unknown"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--model" ]]; then
    model="$arg"
  fi
  prev="$arg"
done
if (( count % 2 == 1 )); then
  printf '{"type":"user","text":"rate limit exceeded"}\n' >&2
  exit 1
fi
printf '{"type":"system","subtype":"init","model":"claude-%s-stub","mcp_servers":[]}\n' "$model"
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0}\n'
EOF
chmod +x "$RETRY_STUB"
mkdir -p "$TEST_TMPDIR/wt8"

OUT=$(
  cd "$F8" && TMPDIR="$TEST_TMPDIR/wt8" CLAUDE_BIN="$RETRY_STUB" RETRY_COUNTER_FILE="$RETRY_COUNTER" \
    bash "$DRIVER" --prompt-file "$PROMPT_FILE" --patch "$PATCH8" \
    --model fable --trials 1 --label retry --out "$TEST_TMPDIR/out8" \
    --stagger-seconds 0 2>&1
)
RC=$?
assert_exit "RETRYABLE transport failure batch exits 0 after retry" 0 "$RC"
assert_contains "RETRYABLE ledger row" "$(cat "$TEST_TMPDIR/out8/results.md")" "RETRYABLE"
assert_contains "retry succeeded ledger row" "$(cat "$TEST_TMPDIR/out8/results.md")" "| OK |"

# --- Case: FAILED-INFRA on usage-policy hard-fail (no retry) ---

F9="$TEST_TMPDIR/f9"
make_fixture "$F9"
PATCH9="$TEST_TMPDIR/relax9.patch"
make_patch "$F9" "$PATCH9"
POLICY_STUB="$TEST_TMPDIR/policy-stub.sh"
cat >"$POLICY_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
model="unknown"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--model" ]]; then
    model="$arg"
  fi
  prev="$arg"
done
printf '{"type":"system","subtype":"init","model":"claude-%s-stub","mcp_servers":[]}\n' "$model"
printf '{"type":"user","text":"usage policy violation"}\n'
exit 1
EOF
chmod +x "$POLICY_STUB"
mkdir -p "$TEST_TMPDIR/wt9"

OUT=$(
  cd "$F9" && TMPDIR="$TEST_TMPDIR/wt9" CLAUDE_BIN="$POLICY_STUB" \
    bash "$DRIVER" --prompt-file "$PROMPT_FILE" --patch "$PATCH9" \
    --model fable --trials 1 --label policy --out "$TEST_TMPDIR/out9" \
    --stagger-seconds 0 2>&1
)
RC=$?
assert_exit "usage-policy hard-fail exits 1" 1 "$RC"
assert_contains "FAILED-INFRA ledger row" "$(cat "$TEST_TMPDIR/out9/results.md")" "FAILED-INFRA"
assert_not_contains "usage-policy failure does not retry to OK" "$(cat "$TEST_TMPDIR/out9/results.md")" "| OK |"

# --- Case: model mismatch is FAILED-INFRA ---

F10="$TEST_TMPDIR/f10"
make_fixture "$F10"
PATCH10="$TEST_TMPDIR/relax10.patch"
make_patch "$F10" "$PATCH10"
MISMATCH_STUB="$TEST_TMPDIR/mismatch-stub.sh"
cat >"$MISMATCH_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"type":"system","subtype":"init","model":"claude-wrong-model-stub","mcp_servers":[]}\n'
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0}\n'
EOF
chmod +x "$MISMATCH_STUB"
mkdir -p "$TEST_TMPDIR/wt10"

OUT=$(
  cd "$F10" && TMPDIR="$TEST_TMPDIR/wt10" CLAUDE_BIN="$MISMATCH_STUB" \
    bash "$DRIVER" --prompt-file "$PROMPT_FILE" --patch "$PATCH10" \
    --model fable --trials 1 --label mismatch --out "$TEST_TMPDIR/out10" \
    --stagger-seconds 0 2>&1
)
RC=$?
assert_exit "model mismatch batch exits 1" 1 "$RC"
assert_contains "model mismatch ledger row" "$(cat "$TEST_TMPDIR/out10/results.md")" "model mismatch"

assert_real_hub_unchanged
report
