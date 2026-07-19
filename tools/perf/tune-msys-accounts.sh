#!/usr/bin/env bash
# Tune MSYS2/Git-for-Windows account lookups for fast process spawns.
#
# On AzureAD/domain accounts, every new MSYS process tree resolves the
# current user/group against the Windows account DB (`passwd: files db` in
# /etc/nsswitch.conf with no /etc/passwd file) — a per-spawn tax that
# inflates bash/git/jq startup (Cygwin FAQ "Why is my shell so slow?";
# see git log -- .work/shell-test-windows-perf/ for sources). The fix is
# to cache the account info in /etc/passwd + /etc/group and stop
# consulting the account DB.
#
# /etc lives under the Git-for-Windows install dir (C:\Program Files\Git\etc)
# — writes require an ELEVATED shell. Git-for-Windows upgrades replace
# nsswitch.conf, so re-run --check after upgrading (the /onboard runtime
# check also flags drift).
#
# Usage:
#   bash tools/perf/tune-msys-accounts.sh --check    # report state; exit 1 on drift
#   bash tools/perf/tune-msys-accounts.sh --apply    # write files (elevated shell)
#   bash tools/perf/tune-msys-accounts.sh --revert   # restore stock state (elevated)
#   bash tools/perf/tune-msys-accounts.sh --help
#
# Exit: 0 success / already tuned; 1 drift (--check) or failure; 2 usage error.

set -uo pipefail

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Overridable for tests — point at a fixture /etc.
ETC_DIR="${MSYS_TUNE_ETC_DIR:-/etc}"
NSSWITCH="$ETC_DIR/nsswitch.conf"
PASSWD="$ETC_DIR/passwd"
GROUP="$ETC_DIR/group"

# nsswitch line is tuned when the active (uncommented) value is exactly
# `files` — i.e. `db` does not appear before any `#`.
_line_tuned() {
  local key="$1" line
  line=$(grep -E "^${key}:" "$NSSWITCH" 2>/dev/null | head -1)
  [[ -n "$line" ]] || return 1
  local active="${line%%#*}"
  [[ "$active" != *db* ]]
}

check_state() {
  local drift=0
  if [[ -s "$PASSWD" ]]; then
    printf 'OK    %s exists (%d entries)\n' "$PASSWD" "$(wc -l <"$PASSWD")"
  else
    printf 'DRIFT %s missing — account lookups hit the Windows account DB\n' "$PASSWD"
    drift=1
  fi
  if [[ -s "$GROUP" ]]; then
    printf 'OK    %s exists (%d entries)\n' "$GROUP" "$(wc -l <"$GROUP")"
  else
    printf 'DRIFT %s missing\n' "$GROUP"
    drift=1
  fi
  local key
  for key in passwd group; do
    if _line_tuned "$key"; then
      printf 'OK    nsswitch.conf %s: db disabled\n' "$key"
    else
      printf 'DRIFT nsswitch.conf %s: still consults db\n' "$key"
      drift=1
    fi
  done
  return "$drift"
}

require_writable_etc() {
  if [[ ! -w "$NSSWITCH" ]]; then
    printf 'tune-msys-accounts: %s is not writable — run from an ELEVATED shell, e.g.:\n' "$NSSWITCH" >&2
    printf "  powershell -Command \"Start-Process -Verb RunAs -FilePath '%s' -ArgumentList '-lc','bash %s %s'\"\n" \
      "$(cygpath -w "$(command -v bash)" 2>/dev/null || printf 'C:\\Program Files\\Git\\usr\\bin\\bash.exe')" \
      "$(printf '%s' "${BASH_SOURCE[0]}" | sed 's/ /\\ /g')" "$1" >&2
    return 1
  fi
}

# Rewrite the active part of `passwd:`/`group:` lines to `files`, keeping
# the old value as a trailing comment. Writes via temp + cat (preserves the
# file's ACLs, unlike mv which would carry the temp file's).
tune_nsswitch() {
  local tmp
  tmp=$(mktemp)
  sed -E \
    -e 's/^(passwd:)[^#]*db[^#]*(#.*)?$/\1 files # db disabled by tune-msys-accounts.sh/' \
    -e 's/^(group:)[^#]*db[^#]*(#.*)?$/\1 files # db disabled by tune-msys-accounts.sh/' \
    "$NSSWITCH" >"$tmp" || return 1
  cat "$tmp" >"$NSSWITCH" || return 1
  rm -f "$tmp"
}

apply_tuning() {
  require_writable_etc --apply || return 1
  command -v mkpasswd >/dev/null 2>&1 || {
    printf 'tune-msys-accounts: mkpasswd not found (need full Git for Windows / MSYS2 install)\n' >&2
    return 1
  }

  # One-time backup of the stock nsswitch.conf (skip if a backup exists).
  if ! ls "$NSSWITCH".bak-* >/dev/null 2>&1; then
    cp "$NSSWITCH" "$NSSWITCH.bak-$(printf '%(%Y%m%d%H%M%S)T' -1)" || return 1
  fi

  # -l local accounts, -c current (AzureAD/domain) user. Comments are not
  # supported in these files — provenance is recorded in the backup name +
  # this script being the only writer.
  mkpasswd -l -c >"$PASSWD" || return 1
  mkgroup -l -c >"$GROUP" || return 1
  tune_nsswitch || return 1

  printf 'tune-msys-accounts: applied. New MSYS process trees skip account-DB lookups.\n'
  printf 'Verify with: bash tools/perf/spawn-benchmark.sh (compare against prior run)\n'
}

revert_tuning() {
  require_writable_etc --revert || return 1
  local latest
  latest=$(ls -1t "$NSSWITCH".bak-* 2>/dev/null | head -1)
  if [[ -n "$latest" ]]; then
    cat "$latest" >"$NSSWITCH" || return 1
    printf 'tune-msys-accounts: restored %s from %s\n' "$NSSWITCH" "$latest"
  else
    printf 'tune-msys-accounts: no backup found for %s — leaving it untouched\n' "$NSSWITCH" >&2
  fi
  # Stock Git for Windows ships no /etc/passwd or /etc/group.
  rm -f "$PASSWD" "$GROUP"
  printf 'tune-msys-accounts: removed %s and %s (stock state)\n' "$PASSWD" "$GROUP"
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  --check)
    check_state
    exit $?
    ;;
  --apply)
    apply_tuning
    exit $?
    ;;
  --revert)
    revert_tuning
    exit $?
    ;;
  *)
    printf 'tune-msys-accounts: expected --check | --apply | --revert | --help\n' >&2
    exit 2
    ;;
esac
