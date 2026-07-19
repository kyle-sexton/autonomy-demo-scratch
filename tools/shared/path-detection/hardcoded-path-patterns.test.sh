#!/usr/bin/env bash
# Black-box regression tests for tools/shared/path-detection/hardcoded-path-patterns.sh.
# Asserts on stdout output and return code of `hpp::scan_text`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=hardcoded-path-patterns.sh
source "$SCRIPT_DIR/hardcoded-path-patterns.sh"

# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

# scan <content> [project-root] [file-path] -> sets OUT and RC
scan() {
  OUT=$(hpp::scan_text "$@")
  RC=$?
}

# --- Clean inputs return 0, no output ---

scan "echo hello world"
assert_exit "clean text returns 0" 0 "$RC"
assert_silent "clean text has no output" "$OUT"

scan 'use $HOME/.config and ~/dotfiles for personal state'
assert_exit "$HOME and ~/ are safe (return 0)" 0 "$RC"
assert_silent "$HOME and ~/ produce no output" "$OUT"

scan 'placeholder syntax /Users/<user>/foo and /home/${USER}/bar and C:\Users\${user}\baz'
assert_exit "placeholder syntax is exempt (return 0)" 0 "$RC"
assert_silent "placeholder syntax produces no output" "$OUT"

# --- Windows user paths ---

scan 'open file at C:\Users\alice\Documents\notes.txt please'
assert_exit "Windows user path returns 1" 1 "$RC"
assert_contains "Windows user path label" "$OUT" "Windows user path detected"

scan 'forward slashes too: C:/Users/bob/Downloads/x'
assert_exit "Windows fwd-slash user path returns 1" 1 "$RC"
assert_contains "Windows fwd-slash user path label" "$OUT" "Windows user path detected"

# --- macOS user paths ---

scan 'config at /Users/alice/Library/Settings.plist'
assert_exit "macOS user path returns 1" 1 "$RC"
assert_contains "macOS user path label" "$OUT" "macOS user path detected"

scan 'shared dir: /Users/Shared/jamf is fine'
assert_exit "/Users/Shared/ is exempt (return 0)" 0 "$RC"
assert_silent "/Users/Shared/ produces no output" "$OUT"

# --- Linux user paths ---

scan 'config at /home/alice/.bashrc'
assert_exit "Linux user path returns 1" 1 "$RC"
assert_contains "Linux user path label" "$OUT" "Linux user path detected"

# --- Windows repo paths ---

scan 'checkout at D:\repos\acme\widget'
assert_exit "Windows repo path returns 1" 1 "$RC"
assert_contains "Windows repo path label" "$OUT" "Windows repo path detected"

scan 'checkout at D:/repos/acme/widget'
assert_exit "Windows fwd-slash repo path returns 1" 1 "$RC"
assert_contains "Windows fwd-slash repo path label" "$OUT" "Windows repo path detected"

scan 'escaped form D:\\repos\\acme\\widget\\'
assert_exit "Escaped Windows repo path returns 1" 1 "$RC"
assert_contains "Escaped Windows repo path label" "$OUT" "Escaped Windows repo path detected"

# --- Gap-2 widening: 8.3 short names + JSON-escaped separators ---
# Acceptance spec for the widened Windows-user/-repo patterns. The base
# single-backslash + forward-slash forms above must KEEP flagging; these add
# the two evasion shapes the youtube incident slipped through: a Windows 8.3
# short-name segment (ends ~<digit>) and a doubled-backslash JSON-escaped
# separator at every position.

# L1: single-separator 8.3 short-name user path
scan 'temp at C:\Users\ALICE~1\AppData\Local\Temp\x please'
assert_exit "L1 single-sep short-name user path returns 1" 1 "$RC"
assert_contains "L1 short-name Windows user label" "$OUT" "Windows user path detected"

# L2: JSON-escaped (doubled backslash) 8.3 short-name user path
scan 'blob "C:\\Users\\ALICE~1\\AppData\\Local\\Temp\\x"'
assert_exit "L2 escaped short-name user path returns 1" 1 "$RC"
assert_contains "L2 escaped short-name Windows user label" "$OUT" "Windows user path detected"

# L3: JSON-escaped NORMAL-name user path — independent of short-name; flags
# only when ALL separator positions accept the doubled backslash.
scan 'blob "C:\\Users\\normaluser\\AppData\\Local\\Temp\\x"'
assert_exit "L3 escaped normal-name user path returns 1" 1 "$RC"
assert_contains "L3 escaped normal-name Windows user label" "$OUT" "Windows user path detected"

# RS1: repo 8.3 short name — single-separator and escaped forms both flag.
scan 'checkout at D:\repos\COMPAN~1\app\bin'
assert_exit "RS1 single-sep short-name repo path returns 1" 1 "$RC"
assert_contains "RS1 short-name Windows repo label" "$OUT" "Windows repo path detected"

scan 'escaped "D:\\repos\\COMPAN~1\\app\\bin\\"'
assert_exit "RS1 escaped short-name repo path returns 1" 1 "$RC"
assert_contains "RS1 escaped short-name repo label" "$OUT" "Escaped Windows repo path detected"

# Gap-2 negatives that MUST stay clean (surgical ~[0-9], not blanket ~-removal):
# a bare-tilde home shorthand is not an 8.3 short name; escaped placeholder
# segments still start with an excluded char (< or $).
scan 'bare tilde C:\Users\~\foo stays a shorthand'
assert_exit "bare-tilde user segment stays clean (return 0)" 0 "$RC"
assert_silent "bare-tilde user segment produces no output" "$OUT"

scan 'escaped placeholders C:\\Users\\<user>\\foo and C:\\Users\\${user}\\bar'
assert_exit "escaped placeholder syntax stays clean (return 0)" 0 "$RC"
assert_silent "escaped placeholder syntax produces no output" "$OUT"

# --- Project root match (machine-specific repo path) ---

scan "absolute /opt/proj/foo.txt reference" "/opt/proj"
assert_exit "project-root match returns 1" 1 "$RC"
assert_contains "machine-specific repo path label" "$OUT" "Machine-specific repo path detected"

scan "no project root context, only safe text" ""
assert_exit "empty project-root skips that pattern (return 0)" 0 "$RC"
assert_silent "empty project-root with clean text has no output" "$OUT"

scan "absolute /opt/proj/foo.txt reference" ""
assert_exit "without project-root, generic abs path is not flagged" 0 "$RC"
assert_silent "without project-root, no machine-specific output" "$OUT"

# --- Multiple violations in one scan ---

MULTI='line A: C:\Users\alice\x
line B: /home/bob/y
line C: /Users/carol/z'
scan "$MULTI"
assert_exit "multi-violation returns 1" 1 "$RC"
assert_contains "multi: Windows user label present" "$OUT" "Windows user path detected"
assert_contains "multi: Linux user label present" "$OUT" "Linux user path detected"
assert_contains "multi: macOS user label present" "$OUT" "macOS user path detected"

# --- Match cap (head -3) ---

MANY=$(printf '/home/u%d/x\n' 1 2 3 4 5)
scan "$MANY"
assert_exit "five-line input returns 1" 1 "$RC"
# Three matches in label block + one trailing blank => 3 lineno: lines max
LINES=$(printf '%s\n' "$OUT" | grep -cE '^[0-9]+:')
assert_eq "match output capped at 3 entries" 3 "$LINES"

# --- Project-root case-insensitive matching ---

scan "Reference D:/REPOS/ACME/WIDGET/file.cs here" "D:/repos/acme/widget"
assert_exit "project-root grep is case-insensitive" 1 "$RC"
assert_contains "case-insensitive label present" "$OUT" "Machine-specific repo path detected"

# --- OS-context exemption (file_path 3rd arg) ---

# Windows path in Windows-context files → suppressed
scan 'use C:\Users\alice\foo' "" "/repo/scripts/setup.ps1"
assert_exit "Win path in .ps1 is suppressed" 0 "$RC"
assert_silent "Win path in .ps1 produces no output" "$OUT"

scan 'use C:\Users\alice\foo' "" "/repo/scripts/setup.psm1"
assert_exit "Win path in .psm1 is suppressed" 0 "$RC"

scan 'use C:\Users\alice\foo' "" "/repo/scripts/setup.cmd"
assert_exit "Win path in .cmd is suppressed" 0 "$RC"

scan 'use C:\Users\alice\foo' "" "/repo/scripts/setup.bat"
assert_exit "Win path in .bat is suppressed" 0 "$RC"

scan 'use C:\Users\alice\foo' "" "/repo/scripts/setup.reg"
assert_exit "Win path in .reg is suppressed" 0 "$RC"

# Windows path in Windows-context directories → suppressed
scan 'use C:\Users\alice\foo' "" "/repo/scripts/windows/setup.sh"
assert_exit "Win path in scripts/windows/ is suppressed" 0 "$RC"

# Windows path in *-windows.* filename → suppressed
scan 'use C:\Users\alice\foo' "" "/repo/setup-windows.sh"
assert_exit "Win path in setup-windows.sh is suppressed" 0 "$RC"

# Windows path in non-OS-scoped file → still flagged
scan 'use C:\Users\alice\foo' "" "/repo/scripts/setup.sh"
assert_exit "Win path in plain .sh still flagged" 1 "$RC"
assert_contains "Win path in plain .sh has Win label" "$OUT" "Windows user path detected"

# Cross-OS leak: macOS path inside Win-context file → still flagged
scan 'use /Users/alice/foo' "" "/repo/scripts/setup.ps1"
assert_exit "cross-OS macOS path in .ps1 still flagged" 1 "$RC"
assert_contains "cross-OS macOS in .ps1 has macOS label" "$OUT" "macOS user path detected"

# macOS path in macOS-context → suppressed
scan 'use /Users/alice/foo' "" "/repo/scripts/macos/setup.sh"
assert_exit "macOS path in scripts/macos/ is suppressed" 0 "$RC"

scan 'use /Users/alice/foo' "" "/repo/setup-macos.sh"
assert_exit "macOS path in setup-macos.sh is suppressed" 0 "$RC"

# Linux path in Linux-context → suppressed
scan 'use /home/bob/foo' "" "/repo/scripts/linux/setup.sh"
assert_exit "Linux path in scripts/linux/ is suppressed" 0 "$RC"

scan 'use /home/bob/foo' "" "/repo/setup-linux.sh"
assert_exit "Linux path in setup-linux.sh is suppressed" 0 "$RC"

# Cross-OS leak: Linux path in Win-context → still flagged
scan 'use /home/bob/foo' "" "/repo/scripts/setup.ps1"
assert_exit "cross-OS Linux path in .ps1 still flagged" 1 "$RC"
assert_contains "cross-OS Linux in .ps1 has Linux label" "$OUT" "Linux user path detected"

# Generic Win-repo pattern in Win-context → suppressed (per AD-2 case 51)
scan 'checkout at D:\repos\acme\widget' "" "/repo/scripts/setup.ps1"
assert_exit "Win-repo pattern in .ps1 is suppressed" 0 "$RC"

# project_root match NEVER suppressed regardless of OS-context (AD-3)
scan "Reference D:/repos/acme/widget/file.cs here" "D:/repos/acme/widget" "/repo/scripts/setup.ps1"
assert_exit "project-root match in .ps1 STILL flagged (AD-3)" 1 "$RC"
assert_contains "project-root in .ps1 has machine-specific label" "$OUT" "Machine-specific repo path detected"

# Uppercase extension matching (case-insensitive)
scan 'use C:\Users\alice\foo' "" "/repo/scripts/SETUP.PS1"
assert_exit "uppercase .PS1 ext is suppressed (case-insensitive)" 0 "$RC"

# Empty file_path (3rd arg "") → no exemption applied (backward-compat)
scan 'use C:\Users\alice\foo' "" ""
assert_exit "empty file_path = no exemption (backward-compat)" 1 "$RC"

# --- Pre-filter gate: superset property (no false negatives) ---
# A cheap pre-filter gate early-returns 0 on clean content but MUST NOT drop
# any true positive. These cases exercise the project-root branch of the gate
# in ISOLATION: the content carries NO OS-path token (Users / /home/ / repos)
# that the OS-path alternation would catch, so only the root-token branch can
# keep them alive. All three separator forms (fwd / backslash / escaped) of a
# repo-root match must still fire. A false-negative gate turns these RED.

scan 'reference C:/work/medley/src/file.cs here' 'C:/work/medley'
assert_exit "gate: fwd-slash repo-root still fires" 1 "$RC"
assert_contains "gate: fwd-slash repo-root label" "$OUT" "Machine-specific repo path detected"

scan 'reference C:\work\medley\src\file.cs here' 'C:/work/medley'
assert_exit "gate: backslash repo-root still fires" 1 "$RC"
assert_contains "gate: backslash repo-root label" "$OUT" "Machine-specific repo path detected"

scan 'reference C:\\work\\medley\\src\\file.cs here' 'C:/work/medley'
assert_exit "gate: escaped repo-root still fires" 1 "$RC"
assert_contains "gate: escaped repo-root label" "$OUT" "Machine-specific repo path detected"

# Repo-root last segment matches case-insensitively (mirrors detailed grep -Fi)
scan 'reference C:/WORK/MEDLEY/src/file.cs here' 'C:/work/medley'
assert_exit "gate: uppercase repo-root still fires (case-insensitive)" 1 "$RC"
assert_contains "gate: uppercase repo-root label" "$OUT" "Machine-specific repo path detected"

# Clean content WITH a project-root set but no leak → fast 0, no output
scan 'totally clean source, no machine paths at all' 'C:/work/medley'
assert_exit "gate: clean content with project-root returns 0" 0 "$RC"
assert_silent "gate: clean content with project-root has no output" "$OUT"

# Clean content, NO project-root → fast 0, no output
scan 'echo done; const x = 1; print("ok")'
assert_exit "gate: clean content no project-root returns 0" 0 "$RC"
assert_silent "gate: clean content no project-root has no output" "$OUT"

[[ $FAILED -eq 0 ]] || exit 1
exit 0
