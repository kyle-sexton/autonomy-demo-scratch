# shellcheck shell=bash
# Pattern expansion helpers for rename-reference sweeps.

rename_regex_escape() {
  printf '%s' "$1" | sed 's/[][\\^$.*+?(){}|]/\\&/g'
}

# Substitute the {old}, {new}, {old_bare} placeholders in a pattern template,
# regex-escaping each value. {old_bare} drops a leading slash so path-rooted
# tokens match their relative form.
rename_expand_template() {
  local template="$1" old="$2" new="${3:-}"
  local old_esc new_esc old_bare
  old_esc="$(rename_regex_escape "$old")"
  new_esc="$(rename_regex_escape "$new")"
  old_bare="$(rename_regex_escape "${old#/}")"
  template="${template//\{old\}/$old_esc}"
  template="${template//\{new\}/$new_esc}"
  template="${template//\{old_bare\}/$old_bare}"
  printf '%s' "$template"
}
