#!/usr/bin/env bash
# Full-tree comment-hygiene audit — fast path for repo-wide scans.
#
# Uses git grep for a single-pass coarse filter, then chp::scan_text per hit line
# (authoritative rules in comment-hygiene-patterns.sh). Do not loop chp::scan_file
# over git ls-files — that path is O(files × lines × greps) and unusable on Windows.
#
# Exit: 0 = clean, 1 = violations, 2 = environment error.

set -euo pipefail

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
  echo ""
  echo "Usage: scan-tree.sh [--help]"
  echo ""
  echo "Stdout: path:lineno:kind:detail per violation (empty when clean)."
  echo "Stderr: summary line (clean or violation count)."
}

for arg in "$@"; do
  case "$arg" in
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "scan-tree.sh: unknown arg '$arg' (try --help)" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="${TEST_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [[ -z "$REPO_ROOT" || (! -d "$REPO_ROOT/.git" && ! -f "$REPO_ROOT/.git") ]]; then
  echo "scan-tree.sh: not inside a git repository" >&2
  exit 2
fi

cd "$REPO_ROOT"

# shellcheck source=comment-hygiene-patterns.sh
source "$REPO_ROOT/tools/shared/comment-hygiene/comment-hygiene-patterns.sh"

# Mirrors chp::is_scannable_extension — pathspecs for git grep.
declare -a SCAN_GLOBS=(
  '*.cs' '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.mts' '*.cts'
  '*.py' '*.sh' '*.ps1' '*.razor' '*.cshtml'
)

# Mirrors chp::should_skip_path — shrink git grep corpus before line validation.
declare -a SCAN_EXCLUDES=(
  ':(exclude)AGENTS.md'
  ':(exclude)CLAUDE.md'
  ':(exclude)CLAUDE.local.md'
  ':(exclude)CLAUDE.local.md.template'
  ':(exclude)REVIEW.md'
  ':(exclude)review/**'
  ':(exclude)docs/**'
  ':(exclude).claude/rules/**'
  ':(exclude).prompts/repo-files-audit-unit/**'
  ':(exclude).work/**'
  ':(exclude)sandboxes/**'
  ':(exclude)**/bin/**'
  ':(exclude)**/obj/**'
  ':(exclude)**/node_modules/**'
  ':(exclude)**/.venv/**'
  ':(exclude)**/course-digest/data/**'
  ':(exclude).lefthook/pre-commit/comment-hygiene-check.sh'
  ':(exclude).lefthook/pre-commit/comment-hygiene-check.test.sh'
  ':(exclude)tools/shared/comment-hygiene/**'
)

# Superset of chp::_emit_scan_matches triggers — false positives filtered by scan_text.
readonly COARSE_COMMENT_RE='^\s*(//|#).*(\b(TODO|FIXME|HACK|XXX)\b|cc-issue|\b(issue|fixes|closes|tracked:)[[:space:]]*#?[0-9]+|\bPR #[0-9]+|(melodic-software/medley|melodic/medley)#[0-9]+)'

violations=0
while IFS= read -r match; do
  [[ -z "$match" ]] && continue

  file="${match%%:*}"
  rest="${match#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"

  chp::should_skip_path "$file" && continue
  chp::is_scannable_extension "$file" || continue

  scan_out=""
  scan_rc=0
  scan_out="$(chp::scan_text "$content" 2>&1)" || scan_rc=$?
  [[ "$scan_rc" -eq 0 ]] && continue

  while IFS= read -r detail_line; do
    [[ -z "$detail_line" ]] && continue
    printf '%s:%s:%s\n' "$file" "$lineno" "$detail_line"
    violations=$((violations + 1))
  done <<<"$scan_out"
done < <(
  git grep -nE "$COARSE_COMMENT_RE" -- "${SCAN_GLOBS[@]}" "${SCAN_EXCLUDES[@]}" 2>/dev/null || true
)

if [[ "$violations" -eq 0 ]]; then
  echo "comment-hygiene scan-tree: clean" >&2
  exit 0
fi

echo "comment-hygiene scan-tree: $violations violation(s)" >&2
exit 1
