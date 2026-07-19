#!/usr/bin/env bash
# Regression tests for tools/github-events/channel-gate.sh.
# Black-box: stub gh + curl on PATH, drive state-file fixtures via the
# GITHUB_EVENTS_STATE_DIR / GITHUB_EVENTS_REPO_SLUG overrides the SSOT lib honors.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/channel-gate.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAILED=0
CASE_NUM=0
# shellcheck source=../../tests/shell/lib.sh
source "$(git rev-parse --show-toplevel)/tests/shell/lib.sh"

# --- stub bin (gh, curl) prepended to PATH; real jq/grep/tr/sed still resolve ---
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "extension list" ]]; then
  [[ "${STUB_GH_EXT:-0}" == "1" ]] && printf 'cli/gh-webhook\tcli/gh-webhook\tv0.2.0\n'
fi
exit 0
EOF
cat >"$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
[[ "${STUB_CURL_OK:-0}" == "1" ]] && exit 0
exit 7
EOF
# Stub `ps` so the gate-4 identity check is deterministic across platforms
# (real Cygwin/MSYS2 `ps` on Git Bash lacks `-o args=`). STUB_PS_ARGS controls
# the args string returned for `ps -p <pid> -o args=`; STUB_PS_ABSENT=1 makes
# the stub emit nothing (simulating ps unavailable / unable to report args ->
# the gate must fall back to the kill -0 liveness result).
cat >"$STUB_BIN/ps" <<'EOF'
#!/usr/bin/env bash
[[ "${STUB_PS_ABSENT:-0}" == "1" ]] && exit 0
printf '%s\n' "${STUB_PS_ARGS:-}"
exit 0
EOF
chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl" "$STUB_BIN/ps"

# run_gate <case-state-dir> [args...] — emits "EXIT:<code>" last line after stdout.
# Per-case env (STUB_GH_EXT, STUB_CURL_OK) inherited from caller exports.
run_gate() {
  local state_dir="$1"
  shift
  local out
  out=$(
    PATH="$STUB_BIN:$PATH" \
      GITHUB_EVENTS_STATE_DIR="$state_dir" \
      GITHUB_EVENTS_REPO_SLUG="test" \
      bash "$GATE" --quiet "$@" 2>/dev/null
  )
  local code=$?
  printf '%s\nEXIT:%s' "$out" "$code"
}

mk_state() {
  local d="$TEST_TMPDIR/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- Case: --help ---
help_out=$(bash "$GATE" --help 2>&1)
assert_exit "--help exit 0" 0 "$?"
assert_contains "--help describes the gate" "$help_out" "channel-mode activation gate"

# --- Case: unknown arg ---
bash "$GATE" --bogus >/dev/null 2>&1
assert_exit "unknown arg exit 3" 3 "$?"

# --- Case: extension missing (gate 1 fails) ---
SD=$(mk_state ext-missing)
export STUB_GH_EXT=0 STUB_CURL_OK=1
r=$(run_gate "$SD")
assert_contains "ext-missing -> CHANNEL_OFF extension" "$r" "CHANNEL_OFF gate=extension"
assert_contains "ext-missing exit 1" "$r" "EXIT:1"

# --- Case: port file missing (gate 2 fails) ---
SD=$(mk_state port-missing)
export STUB_GH_EXT=1 STUB_CURL_OK=1
r=$(run_gate "$SD")
assert_contains "port-missing -> CHANNEL_OFF port-file" "$r" "CHANNEL_OFF gate=port-file"
assert_contains "port-missing exit 1" "$r" "EXIT:1"

# --- Case: broker health fails (gate 3 fails) ---
SD=$(mk_state health-fail)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
export STUB_GH_EXT=1 STUB_CURL_OK=0
r=$(run_gate "$SD")
assert_contains "health-fail -> CHANNEL_OFF broker-health" "$r" "CHANNEL_OFF gate=broker-health"
assert_contains "health-fail exit 1" "$r" "EXIT:1"

# --- Case: watcher PID dead (gate 4 fails) ---
SD=$(mk_state pid-dead)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
printf '999999' >"$SD/watcher-test.pid"
export STUB_GH_EXT=1 STUB_CURL_OK=1
r=$(run_gate "$SD")
assert_contains "pid-dead -> CHANNEL_OFF watcher-pid" "$r" "CHANNEL_OFF gate=watcher-pid"
assert_contains "pid-dead exit 1" "$r" "EXIT:1"

# --- Case: all gates pass (ps reports matching watcher args) ---
SD=$(mk_state all-pass)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
printf '%s' "$$" >"$SD/watcher-test.pid" # this test's own PID — alive
export STUB_GH_EXT=1 STUB_CURL_OK=1 STUB_PS_ABSENT=0
export STUB_PS_ARGS="gh webhook forward --repo=foo/bar --events=* --url=http://127.0.0.1:58620/webhook"
r=$(run_gate "$SD")
assert_contains "all-pass -> CHANNEL_READY" "$r" "CHANNEL_READY receiver=58620 broker=58621"
assert_contains "all-pass exit 0" "$r" "EXIT:0"

# --- Case: Windows gh.exe full-path watcher args pass gate 4 (codex r3327091560) -
# On Git Bash/Windows `ps -o args=` reports the native executable form
# `.../gh.exe webhook forward`, which lacks the literal `gh webhook forward`
# substring. The gate must accept the gh.exe form so a healthy native-Windows
# watcher is not mis-flagged as PID reuse -> false CHANNEL_OFF.
SD=$(mk_state gh-exe)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
printf '%s' "$$" >"$SD/watcher-test.pid"
export STUB_GH_EXT=1 STUB_CURL_OK=1 STUB_PS_ABSENT=0
export STUB_PS_ARGS="C:\\Program Files\\GitHub CLI\\gh.exe webhook forward --repo=foo/bar --events=* --url=http://127.0.0.1:58620/webhook"
r=$(run_gate "$SD")
assert_contains "gh-exe full path -> CHANNEL_READY" "$r" "CHANNEL_READY receiver=58620 broker=58621"
assert_contains "gh-exe full path exit 0" "$r" "EXIT:0"

# --- Case: gate 4 identity mismatch (reused PID) -> CHANNEL_OFF watcher-pid ---
# PID is alive (own PID) but ps reports args that are NOT 'gh webhook forward':
# the kernel reassigned the PID to an unrelated process. Must false-fail-safe.
SD=$(mk_state pid-reuse)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
printf '%s' "$$" >"$SD/watcher-test.pid"
export STUB_GH_EXT=1 STUB_CURL_OK=1 STUB_PS_ABSENT=0
export STUB_PS_ARGS="node /some/unrelated/process.js"
r=$(run_gate "$SD")
assert_contains "pid-reuse -> CHANNEL_OFF watcher-pid" "$r" "CHANNEL_OFF gate=watcher-pid"
assert_contains "pid-reuse exit 1" "$r" "EXIT:1"

# --- Case: gate 4 watcher forwards to a STALE port -> CHANNEL_OFF watcher-pid --
# Broker respawned on a new receiver port (port file = 58620), but the watcher
# still forwards to the old port (58999). Without this check the gate reports
# READY and channel mode silently misses every PR event. (codex P2)
SD=$(mk_state stale-port)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
printf '%s' "$$" >"$SD/watcher-test.pid"
export STUB_GH_EXT=1 STUB_CURL_OK=1 STUB_PS_ABSENT=0
export STUB_PS_ARGS="gh webhook forward --repo=foo/bar --events=* --url=http://127.0.0.1:58999/webhook"
r=$(run_gate "$SD")
assert_contains "stale-port -> CHANNEL_OFF watcher-pid" "$r" "CHANNEL_OFF gate=watcher-pid"
assert_contains "stale-port exit 1" "$r" "EXIT:1"

# --- Case: gate 4 non-numeric PID file -> CHANNEL_OFF watcher-pid (claude #3) --
# A corrupt PID body ("-1") must be rejected before reaching kill -0; bare
# `kill -0 -1` is "all processes" on POSIX and would spuriously pass liveness.
SD=$(mk_state pid-corrupt)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
printf -- '-1' >"$SD/watcher-test.pid"
export STUB_GH_EXT=1 STUB_CURL_OK=1
r=$(run_gate "$SD")
assert_contains "pid-corrupt -> CHANNEL_OFF watcher-pid" "$r" "CHANNEL_OFF gate=watcher-pid"
assert_contains "pid-corrupt exit 1" "$r" "EXIT:1"

# --- Case: ps cannot report args -> graceful fallback to kill -0 (pass) ---
# When ps emits nothing (unavailable or no -o support), the identity check is
# skipped and the gate trusts the kill -0 liveness result. Alive PID -> READY.
SD=$(mk_state ps-absent)
printf '{"receiver":58620,"broker":58621}\n' >"$SD/broker-test.ports.json"
printf '%s' "$$" >"$SD/watcher-test.pid"
export STUB_GH_EXT=1 STUB_CURL_OK=1 STUB_PS_ABSENT=1
unset STUB_PS_ARGS
r=$(run_gate "$SD")
assert_contains "ps-absent -> CHANNEL_READY (graceful fallback)" "$r" "CHANNEL_READY receiver=58620 broker=58621"
assert_contains "ps-absent exit 0" "$r" "EXIT:0"

[[ $FAILED -eq 0 ]] || exit 1
