#!/usr/bin/env bash
# fill_template — substitute named ${VAR} placeholders in a work-artifact
# template and print the result. Sourced by scaffold-artifact.sh and (later)
# ensure-slice-manifest.sh; never executed directly.
#
# Placeholder set: FILL_TEMPLATE_VARS. A template uses any subset; an unset
# placeholder substitutes to empty (nameref + `${ref:-}` default) so a
# subset-using template never trips the caller's `set -u`. Only the literal
# braced token `${VAR}` is replaced — `<fill: …>` markers carry no `${...}`
# form and are left untouched for the model to resolve.
#
# Pure-bash parameter expansion (no envsubst): fork-free + cross-platform
# (gettext is keg-only on macOS) + controlled (only the named vars substitute).
#
# Trailing newline: `$(<file)` strips trailing newlines; output restores exactly
# one so filled output is byte-for-byte stable across templates (matches the
# heredoc forms it replaces).
#
# Usage (from a sourcing script that has set the placeholder vars):
#   source "$SCRIPT_DIR/lib/fill-template.sh"
#   fill_template "$SCRIPT_DIR/templates/journal.md" >"$out"

# No `set -e`: sourced into callers that own their strictness. `${ref:-}`
# defaults keep unset placeholders safe under the callers' `set -u`.
set -uo pipefail

# Named placeholders fill_template substitutes. Add a row here AND a `${VAR}`
# token in a template to introduce a new placeholder. Plain (not readonly) so
# re-sourcing the lib does not error on re-assignment.
FILL_TEMPLATE_VARS=(SLUG SLUG_TITLE DATE TIMESTAMP TYPE TOPIC SESSION_ID)

# fill_template <template-path> — print the template with placeholders filled.
fill_template() {
  local template_path="$1"
  local content var token
  content="$(<"$template_path")"
  for var in "${FILL_TEMPLATE_VARS[@]}"; do
    # nameref reads the value of the variable named by $var without indirect
    # expansion (`${!var:-}` is unsupported on Git Bash 5.2 MSYS).
    local -n ref="$var"
    token="\${$var}"
    content="${content//"$token"/${ref:-}}"
    unset -n ref
  done
  printf '%s\n' "$content"
}
