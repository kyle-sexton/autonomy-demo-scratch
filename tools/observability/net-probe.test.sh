#!/usr/bin/env bash
# Tests for otel/net-probe.sh — the portable port_status listen probe.
#
# Coverage note (read before trusting this): the original bug is /dev/tcp being
# compiled OUT on MSYS2/Git-Bash, where the old probe always read "free". That
# exact condition is NOT reproducible here (this CI/Cygwin box HAS /dev/tcp), so
# these cases instead exercise BOTH code branches independently:
#   * curl branch  — the path taken on MSYS2 (Git for Windows ships curl), proven
#                    correct here against a real listener.
#   * /dev/tcp fallback — forced by stripping curl from PATH; proves the no-curl
#                    path still classifies correctly.
# Together they cover the function; neither claims to reproduce the absent-/dev/tcp
# platform itself.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=net-probe.sh
source "$SCRIPT_DIR/net-probe.sh"
# shellcheck source=../../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

# Two high ports: one we never bind (free), one the listener binds.
readonly FREE_PORT=49732
readonly LISTEN_PORT=49731

server_pid=""
# Inline trap (repo convention; a named cleanup fn invoked only via trap would
# trip SC2329).
trap 'if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; fi' EXIT

# --- 1. unbound port => free (curl branch, the active path on this host) ---
assert_eq "unbound port => free (curl branch)" "free" "$(port_status "$FREE_PORT")"

# --- 2/3. live listener: detected by curl branch AND by the /dev/tcp fallback ---
# python3 is a repo dependency (codex hooks, mcp-parity) and present on CI.
if command -v python3 >/dev/null 2>&1; then
  python3 -m http.server "$LISTEN_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
  server_pid=$!
  bound=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [[ "$(port_status "$LISTEN_PORT")" == "listening" ]]; then
      bound=1
      break
    fi
    sleep 0.2
  done

  if [[ "$bound" == "1" ]]; then
    assert_eq "live listener => listening (curl branch)" "listening" "$(port_status "$LISTEN_PORT")"
    # Discriminate the FALLBACK: empty PATH makes `command -v curl` miss, so the
    # /dev/tcp branch runs (it uses only bash builtins). $(...) isolates PATH="".
    assert_eq "live listener => listening (/dev/tcp fallback, curl stripped)" \
      "listening" "$(PATH="" port_status "$LISTEN_PORT")"
    assert_eq "unbound port => free (/dev/tcp fallback, curl stripped)" \
      "free" "$(PATH="" port_status "$FREE_PORT")"
  else
    skip_case "python3 http.server did not bind $LISTEN_PORT in time"
  fi
else
  skip_case "no python3 for the live-listener sub-cases"
fi

[[ "${FAILED:-0}" -eq 0 ]] || exit 1
exit 0
