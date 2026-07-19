#!/usr/bin/env bash
# Fail when a committed HTML artifact would fetch a remote resource at RUNTIME.
# Generated HTML artifacts must be self-contained (vendored-inline) so they open
# from file:// with no supply-chain, phone-home, or offline-fragility surface.
# SSOT: docs/conventions/html-artifacts.md "Security — no-remote-fetch".
#
# This is the authoritative (CI-invoked) gate — it has NO kill switch. The
# commit-time bypass lives in the lefthook wrapper
# (.lefthook/pre-commit/html-no-remote-fetch.sh, HOOK_HTML_NO_REMOTE_FETCH_ENABLED),
# which delegates here; CI runs this script directly and is non-bypassable.
#
# Argv contract (mirrors tools/verification/check-machine-specific-paths.sh):
#   - No args (CI / standalone): scan all tracked *.html.
#   - Positional args (lefthook {staged_files}): intersect $@ with the tracked
#     *.html set, scan only that intersection. Empty intersection => clean exit 0.
#   - --help / -h: print usage.
#
# What it matches, per .html, is a runtime-fetch construct whose target is a
# remote (http / https / protocol-relative //) URL — matching on attribute /
# function context PLUS the URL, never a bare URL or a bare word in prose:
#   <script|iframe|img|audio|video|source|embed|object|track src|data="//...">
#   <link href="//...">           CSS url(//...) / @import //...
#   fetch("//...") / new XMLHttpRequest / import("//...") / import ... from "//..."
#   Mermaid securityLevel: loose  (runtime XSS vector — a context-free key)
# Navigation links (<a href="http...">) are intentionally NOT matched (a link is
# not a load), and a bare @import / cdn / http in prose or <code> does not trip.
#
# v1 matcher scope (auditable, not a silent overclaim). The criterion stays
# library-agnostic — "no runtime remote fetch, any origin" — but this v1 detector
# does NOT yet match: <img srcset>, <meta http-equiv="refresh" ... url=>,
# <video poster>, inline-SVG <image xlink:href>, or fetch()/import() whose URL
# arrives through a VARIABLE rather than a quoted string literal (single-, double-,
# AND backtick-quoted literals ARE matched). The corpus uses none of these; extend
# a pattern (+ a fixture) when one appears.
#
# Two keys are CONTEXT-FREE — matched on a literal occurrence regardless of the
# surrounding HTML, because they cannot be URL-gated: `securityLevel: loose` (a
# Mermaid runtime config) and `new XMLHttpRequest` (its remote URL arrives later
# via .open()). Both trip even inside a <code> example, so a doc that must QUOTE
# either anti-pattern belongs in markdown (the convention SSOT is markdown, not a
# committed .html) — keeping this security gate strict.

set -euo pipefail

usage() {
  cat <<'EOF'
html-no-remote-fetch.sh — fail when a committed HTML artifact fetches a remote
resource at runtime (the no-remote-fetch enforcement gate).

Usage:
  html-no-remote-fetch.sh             Scan all tracked *.html.
  html-no-remote-fetch.sh <file>...   Scan only the given paths, intersected
                                      with the tracked *.html set (the
                                      staged-files scope the lefthook lane passes).
  html-no-remote-fetch.sh --help      Print this help.

Exit 0 = clean; exit 1 = a remote-fetch construct was found.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

HTML_GLOB='*.html'

# Remote-URL prefix and quote class, shared by the construct patterns below.
# REMOTE matches an absolute (http/https) or protocol-relative (//) URL start.
REMOTE='(https?:)?//'
BT='`'             # backtick, isolated so the quote class below stays readable
QUOTE="[\"'${BT}]" # single- / double- / backtick-quoted string delimiter: ["'`]

# label|ERE-pattern. Each construct pattern requires the REMOTE URL adjacent to
# the construct (so a bare URL or bare keyword in prose never trips); the two
# context-free exceptions, `securityLevel: loose` and `new XMLHttpRequest`, are
# matched literally (they cannot be URL-gated).
declare -a PATTERNS=(
  "remote <script>/<img>/<iframe>/media src or <object> data|<(script|iframe|img|audio|video|source|embed|object|track)[^>]*[[:space:]](src|data)[[:space:]]*=[[:space:]]*${QUOTE}?${REMOTE}"
  "remote <link href> (stylesheet/preconnect/preload/icon)|<link[^>]*[[:space:]]href[[:space:]]*=[[:space:]]*${QUOTE}?${REMOTE}"
  "CSS @import of a remote URL|@import[[:space:]]*(url\\()?[[:space:]]*${QUOTE}?${REMOTE}"
  "CSS url() of a remote resource|url\\([[:space:]]*${QUOTE}?${REMOTE}"
  "JS fetch() to a remote URL|fetch\\([[:space:]]*${QUOTE}${REMOTE}"
  "JS new XMLHttpRequest|new[[:space:]]+XMLHttpRequest"
  "JS dynamic import() of a remote module|import\\([[:space:]]*${QUOTE}${REMOTE}"
  "JS static import ... from a remote module|import[[:space:]].*from[[:space:]]*${QUOTE}${REMOTE}"
  "Mermaid securityLevel: loose (runtime XSS vector)|securityLevel[[:space:]]*:[[:space:]]*${QUOTE}?loose"
)

# Resolve the scan set. SCAN_PATHS becomes the pathspec list `git grep` reads.
declare -a SCAN_PATHS=("$HTML_GLOB")

if (($# > 0)); then
  # File-args mode: intersect $@ with the tracked *.html set. Empty
  # intersection => nothing in scope => clean exit 0.
  declare -A allowed=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && allowed["$f"]=1
  done < <(git ls-files -- "$HTML_GLOB")

  scoped=()
  for f in "$@"; do
    [[ -n "${allowed[$f]:-}" ]] && scoped+=("$f")
  done

  if ((${#scoped[@]} == 0)); then
    echo "No remote-fetch constructs in committed HTML artifacts."
    exit 0
  fi

  SCAN_PATHS=("${scoped[@]}")
fi

FAILED=0

run_check() {
  local label=$1
  local pattern=$2
  local matches

  matches=$(
    git grep -nIE "$pattern" -- "${SCAN_PATHS[@]}" | head -20 || true
  )

  if [[ -n "$matches" ]]; then
    echo "Remote-fetch construct detected (${label}):" >&2
    echo "$matches" >&2
    echo "" >&2
    FAILED=1
  fi
}

for entry in "${PATTERNS[@]}"; do
  run_check "${entry%%|*}" "${entry#*|}"
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "Committed HTML artifacts must be self-contained — inline the resource (vendored-inline)." >&2
  echo "Policy: docs/conventions/html-artifacts.md \"Security — no-remote-fetch\"." >&2
  exit 1
fi

echo "No remote-fetch constructs in committed HTML artifacts."
