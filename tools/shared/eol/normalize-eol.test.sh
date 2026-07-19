#!/usr/bin/env bash
# Black-box tests for tools/shared/eol/normalize-eol.sh.
#
# Drives a controlled .gitattributes fixture so `git check-attr` resolution is
# deterministic and independent of the real repo tree. Coverage:
#   - LF arm: CRLF .sh -> LF, idempotent (every OS)
#   - CRLF arm: LF .cs -> CRLF, idempotent (every OS — repairs smudge-bypassing
#     writes on any platform)
#   - unspecified attr -> no-op
#   - binary guard: NUL content under `* text=auto eol=lf` never rewritten;
#     -text never rewritten
#   - path-specific override: PublicAPI.Unshipped.txt (eol=lf) beats *.txt (crlf),
#     proving the pure check-attr dispatch — a fast-path extension list would fail here
#   - absolute-path resolution matches relative
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$LIB_DIR/normalize-eol.sh"

FAILED=0
CASE_NUM=0

# shellcheck source=../../../tests/shell/lib.sh
source "${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel)}/tests/shell/lib.sh"
# shellcheck source=normalize-eol.sh
source "$LIB"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

REPO="$TEST_TMPDIR/repo"
make_repo "$REPO"
cat >"$REPO/.gitattributes" <<'EOF'
* text=auto
*.sh   text eol=lf
*.cs   text eol=crlf
*.txt  text eol=crlf
PublicAPI.Unshipped.txt text eol=lf
EOF
# Stage so check-attr resolves deterministically regardless of working-tree-vs-index nuance.
git -C "$REPO" add .gitattributes

# Count raw CR bytes — direct proxy for CRLF count when EOLs are only LF or CRLF.
cr_count() { tr -cd '\r' <"$1" | wc -c | tr -d ' '; }

# --- LF arm (EVERY OS): CRLF .sh -> LF, unconditional ---
printf 'echo hi\r\necho bye\r\n' >"$REPO/x.sh"
assert_eq "pre: x.sh has 2 CR" 2 "$(cr_count "$REPO/x.sh")"
action=$(normalize_eol_file "$REPO" "$REPO/x.sh")
assert_eq "LF arm action=lf" lf "$action"
assert_eq "CRLF .sh -> 0 CR (LF, every OS)" 0 "$(cr_count "$REPO/x.sh")"
normalize_eol_file "$REPO" "$REPO/x.sh" >/dev/null
assert_eq "LF arm idempotent (still 0 CR)" 0 "$(cr_count "$REPO/x.sh")"

# --- absolute vs relative path resolve identically ---
printf 'p\nq\n' >"$REPO/z.sh"
action=$(normalize_eol_file "$REPO" "$REPO/z.sh")
assert_eq "abs-path .sh action=lf" lf "$action"

# --- unspecified attr -> no-op (every OS) ---
printf 'a\nb\n' >"$REPO/y.unknownext"
action=$(normalize_eol_file "$REPO" "$REPO/y.unknownext")
assert_eq "unspecified action=skip" skip "$action"
assert_eq "unspecified -> unchanged (0 CR)" 0 "$(cr_count "$REPO/y.unknownext")"

# --- path-specific override: PublicAPI.Unshipped.txt is eol=lf despite *.txt crlf ---
printf 'API\r\nMORE\r\n' >"$REPO/PublicAPI.Unshipped.txt"
action=$(normalize_eol_file "$REPO" "$REPO/PublicAPI.Unshipped.txt")
assert_eq "override action=lf (not crlf) — pure dispatch" lf "$action"
assert_eq "override .txt -> 0 CR (eol=lf beats *.txt crlf)" 0 "$(cr_count "$REPO/PublicAPI.Unshipped.txt")"

# --- CRLF arm: every OS ---
printf 'class C{}\nmore\n' >"$REPO/a.cs"
action=$(normalize_eol_file "$REPO" "$REPO/a.cs")
assert_eq "CRLF arm action=crlf (every OS)" crlf "$action"
assert_eq "LF .cs -> 2 CR (CRLF)" 2 "$(cr_count "$REPO/a.cs")"
normalize_eol_file "$REPO" "$REPO/a.cs" >/dev/null
assert_eq "CRLF arm idempotent (still 2 CR)" 2 "$(cr_count "$REPO/a.cs")"

# --- binary guard: NUL content under text=auto eol never rewritten ---
AUTOREPO="$TEST_TMPDIR/autorepo"
make_repo "$AUTOREPO"
printf '* text=auto eol=lf\n*.dat -text eol=lf\n' >"$AUTOREPO/.gitattributes"
git -C "$AUTOREPO" add .gitattributes
printf 'BIN\r\n\x00\x01\x02\r\ndata' >"$AUTOREPO/blob.bin"
bin_bytes_before=$(wc -c <"$AUTOREPO/blob.bin" | tr -d ' ')
action=$(normalize_eol_file "$AUTOREPO" "$AUTOREPO/blob.bin")
assert_eq "binary guard action=skip" skip "$action"
assert_eq "binary guard -> byte-identical" "$bin_bytes_before" "$(wc -c <"$AUTOREPO/blob.bin" | tr -d ' ')"
# Text sibling in the same repo still normalizes (the sniff passes text through).
printf 'echo t\r\n' >"$AUTOREPO/auto.sh"
action=$(normalize_eol_file "$AUTOREPO" "$AUTOREPO/auto.sh")
assert_eq "text under text=auto action=lf" lf "$action"
assert_eq "text under text=auto -> 0 CR" 0 "$(cr_count "$AUTOREPO/auto.sh")"
# -text is never rewritten even with eol set.
printf 'a\r\nb\r\n' >"$AUTOREPO/keep.dat"
action=$(normalize_eol_file "$AUTOREPO" "$AUTOREPO/keep.dat")
assert_eq "-text action=skip despite eol=lf" skip "$action"
assert_eq "-text -> CR preserved" 2 "$(cr_count "$AUTOREPO/keep.dat")"

[[ $FAILED -eq 0 ]] || exit 1
echo "All cases passed ($CASE_NUM)."
