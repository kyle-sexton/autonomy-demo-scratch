# shellcheck shell=bash
# Shared comment-hygiene detection patterns for hook layers.
#
# Consumers derive via repo dep-graph or direct source (tools/AGENTS.md shared tier).
#
# Library — NOT executable. Pure functions: no env reads, no exit calls.
# Callers handle I/O, path filtering, and exit-code mapping.
#
# Cross-platform: POSIX ERE only (grep -E).

# chp::_is_skill_data_cache_path <relative-file-path>
#
# Returns 0 for third-party skill data / run snapshots (suffix match — no
# skill path literals; shared tier must not path-cite skills per unit-anatomy).
chp::_is_skill_data_cache_path() {
  local f="$1"
  [[ "$f" == *"/course-digest/data/"* ]] && return 0
  return 1
}

# chp::should_skip_path <relative-file-path>
#
# Returns 0 when the path must not be scanned (teaching examples, policy SSOT,
# work slices, build artifacts, third-party skill data).
chp::should_skip_path() {
  local f="$1"
  chp::_is_skill_data_cache_path "$f" && return 0
  case "$f" in
    AGENTS.md | \
      CLAUDE.local.md | \
      CLAUDE.local.md.template | \
      CLAUDE.md | \
      REVIEW.md | \
      review/* | \
      docs/* | \
      .claude/rules/* | \
      .prompts/repo-files-audit-unit/* | \
      .work/* | \
      sandboxes/* | \
      */bin/* | \
      */obj/* | \
      */node_modules/* | \
      */.venv/* | \
      .lefthook/pre-commit/comment-hygiene-check.sh | \
      .lefthook/pre-commit/comment-hygiene-check.test.sh | \
      tools/shared/comment-hygiene/*) return 0 ;;
    *) return 1 ;;
  esac
}

# chp::is_scannable_extension <relative-file-path>
#
# Returns 0 when the file extension is in the production-code scan set.
chp::is_scannable_extension() {
  local f="$1"
  case "$f" in
    *.cs | *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | \
      *.py | *.sh | *.ps1 | *.razor | *.cshtml) return 0 ;;
    *) return 1 ;;
  esac
}

# chp::_is_work_artifact_phase_token_line <comment-line>
#
# Returns 0 when TODO/DOING/DONE tokens are work-artifact phase grammar, not
# actionable debt markers (e.g. "DONE+DOING+TODO", "Phases: …", "[TODO] phase").
chp::_is_work_artifact_phase_token_line() {
  local line="$1"

  [[ "$line" =~ \[(TODO|DOING|DONE|BLOCKED|ABANDONED|DEFERRED)\] ]] && return 0

  [[ "$line" =~ (^|[[:space:]])(DONE|DOING|TODO|BLOCKED|ABANDONED|DEFERRED)([[:space:]]*([+,/→]|→)[[:space:]]*)(DONE|DOING|TODO|BLOCKED|ABANDONED|DEFERRED) ]] && return 0

  local nocase_was=0
  if shopt -q nocasematch; then
    nocase_was=1
  else
    shopt -s nocasematch
  fi
  if [[ "$line" =~ (^|[[:space:]])(Phases?|Case[[:space:]]+[0-9]+:).*(\b(DONE|DOING|TODO)\b|\[(TODO|DOING|DONE)\][[:space:]]+phase) ]]; then
    [[ $nocase_was -eq 0 ]] && shopt -u nocasematch
    return 0
  fi
  if [[ "$line" =~ (^|[[:space:]])phase\)?[[:space:]]*(tag|grammar|token|marker) ]]; then
    [[ $nocase_was -eq 0 ]] && shopt -u nocasematch
    return 0
  fi
  [[ $nocase_was -eq 0 ]] && shopt -u nocasematch

  return 1
}

# chp::_is_internal_repo_issue_ref <comment-line>
#
# Returns 0 when org/repo#issue points at this repository (not upstream).
chp::_is_internal_repo_issue_ref() {
  local line="$1"
  [[ "$line" =~ (melodic-software/medley|melodic/medley)#[0-9]+ ]]
}

# chp::_match_warning_marker <comment-line> <kind-out-var> <detail-out-var>
#
# Returns 0 when line contains a banned FIXME/HACK/XXX/TODO marker.
chp::_match_warning_marker() {
  local line="$1"
  local -n _kind="$2"
  local -n _detail="$3"
  local nocase_was=0

  if shopt -q nocasematch; then
    nocase_was=1
  else
    shopt -s nocasematch
  fi

  if [[ "$line" =~ (^|[^[:alnum:]_])(FIXME|HACK|XXX)([^[:alnum:]_]|$) ]]; then
    _kind="warning-marker"
    _detail="${BASH_REMATCH[2]}"
    [[ $nocase_was -eq 0 ]] && shopt -u nocasematch
    return 0
  fi

  if [[ "$line" =~ (^|[^[:alnum:]_])TODO([^[:alnum:]_]|$) ]]; then
    _kind="warning-marker"
    _detail="TODO"
    [[ $nocase_was -eq 0 ]] && shopt -u nocasematch
    return 0
  fi

  [[ $nocase_was -eq 0 ]] && shopt -u nocasematch
  return 1
}

# chp::_emit_scan_matches <content>
#
# Internal: prints lineno:kind:detail per match. Returns 1 when any match.
chp::_emit_scan_matches() {
  local content="$1"
  local entry lineno line kind detail
  local violations=0
  local nocase_was=0

  if shopt -q nocasematch; then
    nocase_was=1
  else
    shopt -s nocasematch
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    lineno="${entry%%:*}"
    line="${entry#*:}"

    [[ "$line" =~ ^[[:space:]]*#[[:space:]]*TODO\(encapsulation-audit\): ]] && continue
    chp::_is_work_artifact_phase_token_line "$line" && continue

    if chp::_match_warning_marker "$line" kind detail; then
      printf '%s:%s:%s\n' "$lineno" "$kind" "$detail"
      violations=$((violations + 1))
      continue
    fi

    if [[ "$line" =~ cc-issue ]]; then
      printf '%s:tracker-ref:cc-issue\n' "$lineno"
      violations=$((violations + 1))
      continue
    fi

    if [[ "$line" =~ (^|[^[:alnum:]_])(issue|fixes|closes|tracked:)[[:space:]]*#?[0-9]+ ]]; then
      printf '%s:tracker-ref:issue-reference\n' "$lineno"
      violations=$((violations + 1))
      continue
    fi

    if chp::_is_internal_repo_issue_ref "$line"; then
      printf '%s:tracker-ref:internal-repo-issue\n' "$lineno"
      violations=$((violations + 1))
      continue
    fi

    if [[ "$line" =~ (^|[^[:alnum:]_])PR[[:space:]]*#[0-9]+ ]]; then
      printf '%s:tracker-ref:pr-reference\n' "$lineno"
      violations=$((violations + 1))
      continue
    fi

  done < <(awk '/^[[:space:]]*(\/\/|#)/ { print NR ":" $0 }' <<<"$content")

  [[ $nocase_was -eq 0 ]] && shopt -u nocasematch

  if [[ $violations -gt 0 ]]; then
    return 1
  fi
  return 0
}

# chp::scan_text <content>
#
# Scans comment lines for warning markers and tracker provenance.
#
# Output (stdout): violation lines "lineno:kind:detail" (one per match).
# Exit: 0 = clean, 1 = violations found.
chp::scan_text() {
  chp::_emit_scan_matches "$1"
}

# chp::scan_file <path>
#
# Reads file and delegates to chp::scan_text. Prefixes each output line with
# "<path>:" for caller convenience.
chp::scan_file() {
  local path="$1"
  local content match
  local rc=0

  content="$(<"$path")"
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    printf '%s:%s\n' "$path" "$match"
    rc=1
  done < <(chp::_emit_scan_matches "$content" || true)
  return "$rc"
}
