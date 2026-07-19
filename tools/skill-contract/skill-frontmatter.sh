# shellcheck shell=bash
# Shared SKILL.md frontmatter helpers for skill gates.
# Source from check-skill.sh, skill-contract-check.sh, and future skill validators.
#
# Locally-owned materialization: this lib is also published in the skill-quality
# plugin (melodic-software/claude-code-plugins). It stays in-repo because its
# non-interactive callers (check-skill.sh, tools/list-project-skills.sh) source it
# by repo-relative path — the plugin's CLAUDE_PLUGIN_ROOT copy cannot serve them.
# Lib changes belong upstream in the plugin, not in this local copy.

if [[ -n "${SKILL_FRONTMATTER_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
SKILL_FRONTMATTER_LIB_LOADED=1

# Extract YAML frontmatter (between first two --- fences) from stdin.
skill_frontmatter::extract() {
  awk '
    /^---[[:space:]]*$/ { fence++; if (fence == 1) next; if (fence >= 2) exit }
    fence == 1 { print }
  '
}

# Extract a single-line frontmatter scalar by key (quotes stripped) from stdin.
skill_frontmatter::field() {
  local key="$1"
  awk -v k="$key" '
    $0 ~ "^" k ":[[:space:]]*" {
      sub("^" k ":[[:space:]]*", "")
      print
      exit
    }
  '
}

# Strip ONE outer quote layer — double OR single, not both.
skill_frontmatter::strip_quotes() {
  local s="$1"
  if [[ "$s" == '"'*'"' ]]; then
    s="${s#\"}"
    s="${s%\"}"
  elif [[ "$s" == "'"*"'" ]]; then
    s="${s#\'}"
    s="${s%\'}"
  fi
  printf '%s' "$s"
}

# Sorted-unique single-quoted trigger phrases in stdin text.
# Intra-word apostrophes (contractions like "can't") are stripped first —
# otherwise they read as quote delimiters and manufacture pseudo-phrases
# spanning unrelated prose, which the keyword-preservation gate can never
# reconcile across legitimate description edits.
skill_frontmatter::extract_triggers() {
  sed "s/\\([[:alpha:]]\\)'\\([[:alpha:]]\\)/\\1\\2/g" 2>/dev/null | grep -oE "'[^']+'" 2>/dev/null | sort -u
}
