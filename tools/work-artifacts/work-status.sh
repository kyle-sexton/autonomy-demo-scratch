#!/usr/bin/env bash
# Display status across .work/ slices — an index of all slice manifests, or the
# per-phase view of one slice's PLAN.md.
#
# Reads README.md frontmatter (the machine SSOT) and PLAN.md phase tags per
# `.claude/rules/work-artifacts/manifest.md` and `work-artifacts/plan.md`. DISPLAY + DERIVATION only —
# it never SETS status (that judgment stays human). The --phases rollup is
# advisory: it flags when a slice's README status disagrees with its phase tags,
# but does not edit anything.
#
# Operates on the CWD repo's .work/ (git toplevel); testable against a throwaway
# repo. Trimmed to the two modes with live consumers this slice — index (replaces
# nothing) and --phases (replaces the dropped PLAN.md Progress checklist).
# --reap and --gitignore-candidates are deferred to the slices whose consumers
# need them (see `.claude/rules/work-artifacts/conventions.md` "Deferred").
#
# Usage:
#   work-status.sh                  Index: slug | status | updated | priority | tracker (newest first).
#   work-status.sh --phases <slug>  Per-phase tags + computed rollup for one slice.
#   work-status.sh --help           Show this help.
# Exit: 0 ok | 1 not inside a git repo | 2 usage error.

# No `set -e`: optional frontmatter fields and the not-in-a-repo path are
# expected, explicitly-handled non-zero results.
set -uo pipefail

TAB=$'\t'

usage() {
  cat <<'EOF'
work-status.sh — status across .work/ slices.

Reads README.md frontmatter (machine SSOT) + PLAN.md phase tags. Display only —
never sets status; the --phases rollup is advisory.

Usage:
  work-status.sh                  Index every slice: slug | status | updated | priority | tracker (newest first).
  work-status.sh --phases <slug>  Per-phase tags + computed rollup for one slice.
  work-status.sh --help           Show this help.

Exit codes:
  0  ok
  1  not inside a git repository
  2  usage error
EOF
}

# frontmatter_field <file> <key> — value of a flat-scalar key inside the leading
# `---` frontmatter fence. Empty when the file has no frontmatter or the key is
# absent. Strips surrounding whitespace and a trailing ` # comment`. Flat scalars
# only (no arrays/nesting) per the format spec — keeps this a tiny awk, not a
# YAML parser.
frontmatter_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR == 1 && $0 != "---" { exit }      # no frontmatter
    NR == 1 { next }                      # consume opening fence
    $0 == "---" { exit }                  # closing fence — stop before the body
    index($0, k ":") == 1 {
      line = $0
      sub("^" k ":[[:space:]]*", "", line)
      sub("[[:space:]]+#.*$", "", line)
      sub("[[:space:]]+$", "", line)
      print line
      exit
    }
  ' "$file" 2>/dev/null | tr -d '\r'
}

# frontmatter_fields <file> <key>... — extract several flat-scalar frontmatter
# fields in ONE awk pass (vs one awk spawn per key), emitting `key<TAB>value`
# for each requested key's first occurrence inside the leading `---` fence. Same
# parse rules as frontmatter_field (kept for show_phases' single-key call).
frontmatter_fields() {
  local file="$1"
  shift
  awk -v keys="$*" '
    BEGIN { n = split(keys, want, " ") }
    NR == 1 && $0 != "---" { exit }      # no frontmatter
    NR == 1 { next }                      # consume opening fence
    $0 == "---" { exit }                  # closing fence — stop before the body
    {
      for (i = 1; i <= n; i++) {
        k = want[i]
        if (!(k in seen) && index($0, k ":") == 1) {
          line = $0
          sub("^" k ":[[:space:]]*", "", line)
          sub("[[:space:]]+#.*$", "", line)
          sub("[[:space:]]+$", "", line)
          print k "\t" line
          seen[k] = 1
          break
        }
      }
    }
  ' "$file" 2>/dev/null | tr -d '\r'
}

index_slices() {
  local target_root="$1"
  shopt -s globstar nullglob
  local rows=() readme dir slug status updated priority issue pr tracker _fkey _fval
  for readme in "$target_root"/.work/**/README.md; do
    [[ -f "$readme" ]] || continue
    dir="${readme%/*}"
    slug="${dir#"$target_root"/.work/}"
    # One awk pass for all five fields (was one spawn per key).
    status="" updated="" priority="" issue="" pr=""
    while IFS=$'\t' read -r _fkey _fval; do
      case "$_fkey" in
        status) status="$_fval" ;;
        updated) updated="$_fval" ;;
        priority) priority="$_fval" ;;
        issue) issue="$_fval" ;;
        pr) pr="$_fval" ;;
        *) ;;
      esac
    done < <(frontmatter_fields "$readme" status updated priority issue pr)
    tracker=""
    [[ -n "$issue" ]] && tracker="issue:#$issue"
    [[ -n "$pr" ]] && tracker="${tracker:+$tracker }pr:#$pr"
    rows+=("${slug}${TAB}${status:-?}${TAB}${updated:-0000-00-00}${TAB}${priority:--}${TAB}${tracker:--}")
  done

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "no .work/ slices found (no .work/**/README.md)"
    return 0
  fi

  {
    printf 'slug%sstatus%supdated%spriority%stracker\n' "$TAB" "$TAB" "$TAB" "$TAB"
    printf '%s\n' "${rows[@]}" | sort -t"$TAB" -k3,3 -r
  } | if command -v column >/dev/null 2>&1; then
    column -t -s "$TAB"
  else
    cat
  fi
}

reject_unsafe_slug() {
  local slug="$1"
  if [[ "$slug" == */* || "$slug" == *\\* || "$slug" == *..* ]]; then
    echo "work-status: slug must be a single path segment (no '/', '\\', or '..'): $slug" >&2
    exit 2
  fi
}

show_phases() {
  local target_root="$1" slug="$2"
  reject_unsafe_slug "$slug"
  local slice_dir="$target_root/.work/$slug"
  local plan="$slice_dir/PLAN.md"
  local readme="$slice_dir/README.md"
  local readme_status=""
  [[ -f "$readme" ]] && readme_status="$(frontmatter_field "$readme" status)"

  if [[ ! -f "$plan" ]]; then
    printf 'slice %s has no PLAN.md — XS slice; README status is authoritative.\n' "$slug"
    printf 'README status: %s\n' "${readme_status:-<none>}"
    return 0
  fi

  local todo=0 doing=0 blocked=0 done_=0 abandoned=0 deferred=0 total=0 line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    printf '%s\n' "$line"
    total=$((total + 1))
    case "$line" in
      *'[TODO]') todo=$((todo + 1)) ;;
      *'[DOING]') doing=$((doing + 1)) ;;
      *'[BLOCKED]') blocked=$((blocked + 1)) ;;
      *'[DONE]') done_=$((done_ + 1)) ;;
      *'[ABANDONED]') abandoned=$((abandoned + 1)) ;;
      *'[DEFERRED]') deferred=$((deferred + 1)) ;;
      *) ;;
    esac
  done < <(grep -E '^### Phase [0-9]+: .+ \[(TODO|DOING|BLOCKED|DONE|ABANDONED|DEFERRED)\]$' "$plan")

  printf -- '---\n'
  if [[ $total -eq 0 ]]; then
    printf 'no recognized phase tags in PLAN.md (grammar: "### Phase N: <name> [STATUS]")\n'
    printf 'README status: %s\n' "${readme_status:-<none>}"
    return 0
  fi

  local terminal=$((done_ + abandoned + deferred)) rollup
  if [[ $blocked -gt 0 ]]; then
    rollup="blocked"
  elif [[ $doing -gt 0 ]]; then
    rollup="in-progress"
  elif [[ $done_ -gt 0 && $todo -gt 0 ]]; then
    rollup="in-progress"
  elif [[ $terminal -eq $total && $done_ -gt 0 ]]; then
    rollup="done"
  elif [[ $todo -eq $total ]]; then
    rollup="draft"
  else
    rollup="in-progress"
  fi

  printf 'phases: %d  (todo:%d doing:%d blocked:%d done:%d abandoned:%d deferred:%d)\n' \
    "$total" "$todo" "$doing" "$blocked" "$done_" "$abandoned" "$deferred"
  printf 'computed rollup: %s\n' "$rollup"
  printf 'README status:   %s\n' "${readme_status:-<none>}"

  if [[ -n "$readme_status" && "$readme_status" != "$rollup" ]]; then
    case "$readme_status" in
      abandoned | deferred) ;; # legit whole-slice override, not derivable from phase tags
      draft)
        if [[ "$rollup" != "draft" && "$rollup" != "in-progress" ]]; then
          printf 'NOTE: README status %s differs from computed rollup %s (advisory)\n' "$readme_status" "$rollup"
        fi
        ;;
      *)
        printf 'NOTE: README status %s differs from computed rollup %s (advisory)\n' "$readme_status" "$rollup"
        ;;
    esac
  fi
  return 0
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  *) ;;
esac

target_root="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [[ -z "$target_root" ]]; then
  echo "work-status: not inside a git repository" >&2
  exit 1
fi

case "${1:-}" in
  --phases)
    shift
    if [[ -z "${1:-}" ]]; then
      echo "work-status: --phases requires a <slug>" >&2
      exit 2
    fi
    show_phases "$target_root" "$1"
    ;;
  "")
    index_slices "$target_root"
    ;;
  *)
    printf 'unknown argument: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
