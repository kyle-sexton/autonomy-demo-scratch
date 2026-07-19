#!/usr/bin/env bash
# Regression tests for tools/verification/html-no-remote-fetch.sh.
#
# Each case builds a throwaway tracked git repo, adds .html fixtures, and runs the
# gate inside it (the gate scans via git grep / git ls-files relative to cwd).
# Detection cases assert exit 1 + the construct message; pass cases assert exit 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/html-no-remote-fetch.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# shellcheck source=../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"

DETECTED="Remote-fetch construct detected"
CLEAN="No remote-fetch constructs in committed HTML artifacts"

make_repo() {
  # make_repo <root> — init a tracked git repo at <root>.
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" config commit.gpgsign false
}

add_html() {
  # add_html <root> <relpath> <line>... — write + stage an .html fixture.
  local root="$1" rel="$2"
  shift 2
  local full="$root/$rel"
  mkdir -p "$(dirname "$full")"
  printf '%s\n' "$@" >"$full"
  git -C "$root" add "$rel"
}

run_gate() {
  # run_gate <root> [args...] — run the gate inside <root>, capture stdout+stderr.
  local root="$1"
  shift
  (cd "$root" && bash "$SCRIPT" "$@") 2>&1
}

# Assert the gate, run full-tree inside <root>, exits with <want_rc> and its
# output contains <needle>.
assert_gate() {
  local label="$1" root="$2" want_rc="$3" needle="$4" out rc
  out=$(run_gate "$root")
  rc=$?
  assert_exit "$label (exit)" "$want_rc" "$rc"
  assert_contains "$label (msg)" "$out" "$needle"
}

# Each case gets its own tracked repo, set into the global $ROOT. Do NOT route
# this through a `new_root` command substitution with an internal
# counter — the increment would happen in the subshell and not persist, so every
# case would reuse one repo and leak fixtures across cases (silent false PASS on
# detection cases, false FAIL on clean cases).
new_root() {
  ROOT="$(mktemp -d "$TEST_TMPDIR/repo-XXXXXX")"
  make_repo "$ROOT"
}

# --- Case 1: a self-contained inline artifact passes -------------------------
# Exercises the benign neighbours of every pattern: non-remote url(#id)/url(data:),
# an <a href="https"> navigation link, and bare @import / fetch / XMLHttpRequest
# words in prose — none is a runtime remote fetch, so the gate stays clean.
new_root
add_html "$ROOT" "report.html" \
  '<!DOCTYPE html><html><head><style>' \
  '  body { font-family: system-ui; background: #faf9f5; }' \
  '  .clip { clip-path: url(#mask); }' \
  '  .logo { background: url(data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=); }' \
  '</style></head><body>' \
  '  <a href="https://example.com/docs">external docs</a>' \
  '  <p>A bare @import or the fetch keyword or the XMLHttpRequest API in prose is fine.</p>' \
  '</body></html>'
assert_gate "case 1: clean inline artifact" "$ROOT" "0" "$CLEAN"

# --- Case 2: remote <script src> is detected ---------------------------------
new_root
add_html "$ROOT" "bad.html" '<script src="https://cdn.example.com/lib.js"></script>'
assert_gate "case 2: remote <script src>" "$ROOT" "1" "$DETECTED"

# --- Case 3: remote <link href> stylesheet is detected -----------------------
new_root
add_html "$ROOT" "bad.html" '<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=X">'
assert_gate "case 3: remote <link href>" "$ROOT" "1" "$DETECTED"

# --- Case 4: CSS @import url(http) is detected -------------------------------
new_root
add_html "$ROOT" "bad.html" '<style>@import url(https://cdn.example.com/base.css);</style>'
assert_gate "case 4: @import url(remote)" "$ROOT" "1" "$DETECTED"

# --- Case 5: CSS url(http) background asset is detected -----------------------
new_root
add_html "$ROOT" "bad.html" '<style>.hero { background: url(https://img.example.com/h.png); }</style>'
assert_gate "case 5: url(remote)" "$ROOT" "1" "$DETECTED"

# --- Case 6: JS fetch() to a remote URL is detected --------------------------
new_root
add_html "$ROOT" "bad.html" '<script>fetch("https://api.example.com/data").then(r => r.json());</script>'
assert_gate "case 6: fetch(remote)" "$ROOT" "1" "$DETECTED"

# --- Case 7: new XMLHttpRequest is detected ----------------------------------
new_root
add_html "$ROOT" "bad.html" '<script>var r = new XMLHttpRequest(); r.open("GET", "/x");</script>'
assert_gate "case 7: new XMLHttpRequest" "$ROOT" "1" "$DETECTED"

# --- Case 8: dynamic import() of a remote module is detected -----------------
new_root
add_html "$ROOT" "bad.html" '<script type="module">import("https://cdn.example.com/m.js");</script>'
assert_gate "case 8: dynamic import(remote)" "$ROOT" "1" "$DETECTED"

# --- Case 9: static import ... from a remote module is detected --------------
new_root
add_html "$ROOT" "bad.html" '<script type="module">import mermaid from "https://cdn.jsdelivr.net/npm/mermaid/+esm";</script>'
assert_gate "case 9: static import-from remote" "$ROOT" "1" "$DETECTED"

# --- Case 10: Mermaid securityLevel: loose is detected -----------------------
new_root
add_html "$ROOT" "bad.html" '<script>mermaid.initialize({ startOnLoad: true, securityLevel: "loose" });</script>'
assert_gate "case 10: securityLevel: loose" "$ROOT" "1" "$DETECTED"

# --- Case 11: protocol-relative // src is detected ---------------------------
new_root
add_html "$ROOT" "bad.html" '<script src="//cdn.example.com/lib.js"></script>'
assert_gate "case 11: protocol-relative // src" "$ROOT" "1" "$DETECTED"

# --- Cases 11b-d: backtick template-literal URLs are detected ----------------
# Regression for a verifier-found false-negative: a backtick template literal is
# still a string literal, so the three quote-requiring JS keys (fetch / static
# import-from / dynamic import()) must catch a remote URL spelled with backticks.
new_root
add_html "$ROOT" "bad.html" '<script>fetch(`https://api.example.com/x`).then(r => r.json());</script>'
assert_gate "case 11b: fetch(\`remote\`)" "$ROOT" "1" "$DETECTED"

new_root
add_html "$ROOT" "bad.html" '<script type="module">import m from `https://cdn.example.com/m.js`;</script>'
assert_gate "case 11c: static import-from \`remote\`" "$ROOT" "1" "$DETECTED"

new_root
add_html "$ROOT" "bad.html" '<script type="module">import(`https://cdn.example.com/m.js`);</script>'
assert_gate "case 11d: dynamic import(\`remote\`)" "$ROOT" "1" "$DETECTED"

# --- Case 12: AUDIT.html-shape prose @import in <code> passes ----------------
# The known false-positive shape from the live corpus (AUDIT.html:216): @import
# named inside a <code> tag with no URL after it.
new_root
add_html "$ROOT" "audit.html" \
  '<p>Do NOT introduce a runtime <code>&lt;link&gt;</code>/<code>@import</code> stylesheet.</p>' \
  '<table><tr><td><code>@import</code></td><td>banned in artifacts</td></tr></table>'
assert_gate "case 12: prose @import in <code>" "$ROOT" "0" "$CLEAN"

# --- Case 13: <a href="https"> navigation link passes ------------------------
new_root
add_html "$ROOT" "links.html" '<p>See <a href="https://example.com/page">the page</a>.</p>'
assert_gate "case 13: <a href> navigation" "$ROOT" "0" "$CLEAN"

# --- Case 14: securityLevel value other than loose passes (value-specific) ---
# Proves the key is `loose`-specific, not a broad `securityLevel` keyword match —
# a doc quoting the safe config (or the runtime-strict fallback) must not trip.
new_root
add_html "$ROOT" "strict.html" '<pre><code>mermaid.initialize({ securityLevel: "strict" });</code></pre>'
assert_gate "case 14: securityLevel: strict passes" "$ROOT" "0" "$CLEAN"

# --- Case 15: a .work/**/*.html artifact is in scope -------------------------
new_root
add_html "$ROOT" ".work/some-slice/AUDIT.html" '<script src="https://cdn.example.com/x.js"></script>'
assert_gate "case 15: .work/**/*.html in scope" "$ROOT" "1" "$DETECTED"

# --- Case 17: file-args (lefthook {staged_files}) scope ----------------------
new_root
add_html "$ROOT" "clean.html" '<style>body { color: #000; }</style>'
add_html "$ROOT" "bad.html" '<script src="https://cdn.example.com/x.js"></script>'

out=$( (cd "$ROOT" && bash "$SCRIPT" clean.html) 2>&1)
rc=$?
assert_exit "case 17a: file-arg clean.html (exit)" "0" "$rc"
assert_contains "case 17a: file-arg clean.html (msg)" "$out" "$CLEAN"

out=$( (cd "$ROOT" && bash "$SCRIPT" bad.html) 2>&1)
rc=$?
assert_exit "case 17b: file-arg bad.html (exit)" "1" "$rc"
assert_contains "case 17b: file-arg bad.html (msg)" "$out" "$DETECTED"

# A path not in the .html allowlist (or absent) is a no-op clean exit.
out=$( (cd "$ROOT" && bash "$SCRIPT" notes.md) 2>&1)
rc=$?
assert_exit "case 17d: file-arg non-html (exit)" "0" "$rc"
assert_contains "case 17d: file-arg non-html (msg)" "$out" "$CLEAN"

# --- Case 18: --help prints usage and exits 0 --------------------------------
out=$(bash "$SCRIPT" --help)
rc=$?
assert_exit "case 18: --help (exit)" "0" "$rc"
assert_contains "case 18: --help (usage)" "$out" "no-remote-fetch enforcement gate"

# --- Report ------------------------------------------------------------------
if [[ "$FAILED" -eq 0 ]]; then
  printf '\nAll %d checks passed.\n' "$CASE_NUM"
  exit 0
fi
printf '\n%d/%d checks failed.\n' "$FAILED" "$CASE_NUM" >&2
exit 1
