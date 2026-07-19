#!/usr/bin/env bash
# Derive the repo dependency edge-list on demand — no stored graph.
#
# Emits one TSV row per edge: `from-path<TAB>kind<TAB>target-path`. Kinds:
#   source  bash `source` / `.` include statement (shell files only)
#   exec    `bash <path>` / `sh <path>` invocation (shell + config/doc files)
#   cite    repo-path literal in a doc/config file (.md/.yml/.yaml/.json/.toml)
#
# The primary use is the pre-move consumer query: `--target <prefix>` answers
# "who references X?" before X moves; `--from <prefix>` answers "what does X
# reference?". Both are path-prefix filters on the respective column.
#
# Completeness lever (grep-approximate by design; tree-sitter is the deferred
# precision upgrade): detection is regex-based over a single getline scan of the
# tracked tree — it does NOT resolve shell variable indirection (`bash "$VAR"`),
# and a relative `source ../foo.sh` is only captured when its literal contains a
# top-level-dir-anchored segment. Targets are validated against the tracked
# file + ancestor-dir set, so noise (URLs, non-existent paths) is dropped and a
# `cite` always names something real. This mirrors the ShellCheck
# `external-sources=true` / SC1090-SC1091 literal-path discipline: literal paths
# are analyzable; indirected ones are not.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: derive-dep-edges.sh [options]

Emit the repo dependency edge-list as TSV (`from<TAB>kind<TAB>target`), one row
per edge, sorted and de-duplicated. Kinds: source (shell source/. include),
exec (bash/sh invocation), cite (repo-path literal in .md/.yml/.yaml/.json/.toml).
Targets are validated against the tracked file + ancestor-directory set, so every
edge names a path that actually exists in the tree.

Options:
  --target <prefix>   Keep only edges whose TARGET path starts with <prefix>
                      (the "who references X?" pre-move consumer query).
  --from <prefix>     Keep only edges whose FROM path starts with <prefix>
                      (the "what does X reference?" query).
  --root <dir>        Repo root to enumerate + scan (default: cwd git toplevel).
  --help, -h          Show this help and exit.

Exit codes: 0 success (including an empty edge-list), 2 usage error.
EOF
}

err() { echo "ERROR: $*" >&2; }

# Single-pass POSIX-awk core (no gawk extensions — runs on gawk/mawk/BSD awk).
# stdin = full tracked path list (cwd-relative). The main loop registers every
# path into the validation set (pathset + ancestor dirset) and collects the
# scan-eligible subset; END getline-scans each eligible file, extracts
# top-level-dir-anchored path tokens per line, classifies the edge kind from the
# line context, validates each token, applies the --target/--from filters, and
# prints the surviving edges. No per-file forks; external `sort -u` orders.
read -r -d '' AWK_PROG <<'AWK' || true
BEGIN {
  nscan = 0
}
NF > 0 {
  path = $0
  pathset[path] = 1
  n = split(path, seg, "/")
  acc = ""
  for (i = 1; i < n; i++) {
    acc = (i == 1) ? seg[1] : acc "/" seg[i]
    dirset[acc] = 1
  }
  if (n > 1) topset[seg[1]] = 1
  if (scan_ext(path)) scanlist[++nscan] = path
}
END {
  build_token_re()
  for (i = 1; i <= nscan; i++) scan_file(scanlist[i])
}
function scan_ext(p,   e) {
  if (!match(p, /\.[A-Za-z0-9]+$/)) return 0
  e = substr(p, RSTART + 1)
  return (e == "sh" || e == "bash" || e == "md" || e == "yml" || \
    e == "yaml" || e == "json" || e == "toml")
}
function is_shell(p) {
  return (p ~ /\.(sh|bash)$/)
}
# Build the token-extraction regex from the actual top-level tracked dirs, so a
# literal is only anchored where a real top-level directory begins. Dots in
# dotted roots (.claude/.github/.lefthook) are escaped to match literally.
function build_token_re(   t, esc, alt) {
  alt = ""
  for (t in topset) {
    esc = t
    gsub(/\./, "\\.", esc)
    alt = (alt == "") ? esc : alt "|" esc
  }
  if (alt == "") alt = "\001"
  TOKEN_RE = "(" alt ")/[A-Za-z0-9._/-]*"
}
function scan_file(path,   line, shell, kind) {
  shell = is_shell(path)
  while ((getline line < path) > 0) {
    sub(/\r$/, "", line)
    kind = classify(line, shell)
    if (kind == "") continue
    emit_tokens(path, kind, line)
  }
  close(path)
}
# Edge kind from line context. Shell files yield only source/exec edges (a path
# in a shell comment or assignment is not a dependency under this contract);
# doc/config files yield exec when the line invokes an interpreter, else cite.
function classify(line, shell) {
  if (shell) {
    if (line ~ /^[ \t]*(source|\.)[ \t]/) return "source"
    if (line ~ /(^|[ \t])(bash|sh)[ \t]+/) return "exec"
    return ""
  }
  if (line ~ /(^|[ \t])(bash|sh)[ \t]+/) return "exec"
  return "cite"
}
function emit_tokens(path, kind, line,   work, tok) {
  work = line
  while (match(work, TOKEN_RE)) {
    tok = substr(work, RSTART, RLENGTH)
    work = substr(work, RSTART + RLENGTH)
    sub(/[\/.]+$/, "", tok)
    if (!((tok in pathset) || (tok in dirset))) continue
    if (FROM_PREFIX != "" && substr(path, 1, length(FROM_PREFIX)) != FROM_PREFIX) continue
    if (TARGET_PREFIX != "" && substr(tok, 1, length(TARGET_PREFIX)) != TARGET_PREFIX) continue
    print path "\t" kind "\t" tok
  }
}
AWK

main() {
  local target_prefix="" from_prefix="" root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || {
          err "--target needs a path prefix"
          return 2
        }
        target_prefix="$2"
        shift 2
        ;;
      --from)
        [[ $# -ge 2 ]] || {
          err "--from needs a path prefix"
          return 2
        }
        from_prefix="$2"
        shift 2
        ;;
      --root)
        [[ $# -ge 2 ]] || {
          err "--root needs a path"
          return 2
        }
        root="$2"
        shift 2
        ;;
      --help | -h)
        usage
        return 0
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$root" ]]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  fi
  if [[ -z "$root" ]]; then
    err "not inside a git repository (and no --root given)"
    return 2
  fi

  (
    cd "$root" || exit 1
    git ls-files | tr -d '\r' | LC_ALL=C sort -u \
      | awk -v TARGET_PREFIX="$target_prefix" -v FROM_PREFIX="$from_prefix" "$AWK_PROG"
  ) | LC_ALL=C sort -u
}

main "$@"
