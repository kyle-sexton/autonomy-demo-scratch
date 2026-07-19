# shellcheck shell=bash
# Shared media prerequisite probes (command -v + version floors only).
# Sourced by check-media-prereqs.sh facade; bootstrap may source in a follow-up slice.

media_prereq_version_ge() {
  local have="$1" floor="$2"
  local have_maj have_min want_maj want_min
  have_maj="${have%%.*}"
  have_min="${have#*.}"
  have_min="${have_min%%.*}"
  want_maj="${floor%%.*}"
  want_min="${floor#*.}"
  want_min="${want_min%%.*}"
  ((10#$have_maj > 10#$want_maj || (10#$have_maj == 10#$want_maj && 10#$have_min >= 10#$want_min)))
}

media_prereq_parse_version() {
  local raw="$1"
  printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# Emit four-line fact block for one binary.
# Usage: media_prereq_emit_fact <cmd> <display> <floor|-> <required true|false>
media_prereq_emit_fact() {
  local cmd="$1" display="$2" floor="$3" required="$4"
  local raw version status="missing"

  if command -v "$cmd" >/dev/null 2>&1; then
    raw="$("$cmd" --version 2>/dev/null | tr -d '\r' | head -n1)"
    version="$(media_prereq_parse_version "$raw")"
    if [[ -z "$version" ]]; then
      status="present"
      version="unknown"
    elif [[ "$floor" == "-" ]] || media_prereq_version_ge "$version" "$floor"; then
      status="present"
    else
      status="below-floor"
    fi
  else
    version="n/a"
  fi

  printf 'Tool: %s\n' "$display"
  printf 'Status: %s\n' "$status"
  printf 'Version: %s\n' "$version"
  printf 'Required: %s\n' "$required"
}
