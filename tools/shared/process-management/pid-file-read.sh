#!/usr/bin/env bash
# Shared PID-file reader for tools/ supervisor scripts.
#
# Consumers derive on demand via the repo dep-graph edge scan
# (tools/AGENTS.md "Vertical slices" — dep-graph row).
#
# Library — NOT executable. Pure-function: no env reads, no stdin parsing,
# no exit calls. Callers handle file-existence checks, error fallbacks, and
# downstream PID-liveness validation (kill -0, ps -p args= for reuse defense).
#
# Why strip `\r\n[:space:]`:
#   - Git Bash on Windows appends `\r` to piped output and to some printf
#     forms, breaking `kill -0 <pid>` and arithmetic comparisons (see
#     bash/conventions.md "Git Bash on Windows" + `tr -d '\r'` gotcha).
#   - PID writers may emit trailing newline or leading whitespace; strip both
#     so the consumer never has to think about format drift.

# pid_file::read <pid_file>
#
# Reads <pid_file> and prints its content with CRLF + whitespace stripped.
# Does NOT verify file existence — caller decides whether absence is fatal
# or expected (cold start vs orphan-cleanup).
#
# Stdin: ignored. Stdout: cleaned PID string (may be empty if file is empty).
# Stderr: filesystem error from `tr` if file missing (caller may suppress).
# Exit: tr's exit code (0 on success, non-zero on read failure).
#
# Pair with `2>/dev/null || true` (non-fatal, allow empty) or
# `2>/dev/null || echo "?"` (display fallback) at call site as needed.
pid_file::read() {
  tr -d '\r\n[:space:]' <"$1"
}
