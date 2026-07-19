#!/usr/bin/env bash
# extract-declared-labels.sh — emit the authoritative declared label NAMES for a
# repo, derived AT RUNTIME from the github-iac SSOT: the org/personal Labels.cs
# `_core` set unioned with the repo's `ExtraLabels` in GovernedRepositories.cs.
#
# The set is never snapshotted into medley — github-iac is the sole owner of the
# label definitions, and this reads them live from a checkout so there is no
# copy to drift. That is also why this REGEX-PARSES C# tuple literals: medley
# has no typed access to the Pulumi model, so it reconstructs the declared set
# from source shape. In github-iac itself the same check would read the model
# (or `pulumi preview`) directly — see the cross-repo-home note on the PR.
#
# Extraction anchors on the tuple SHAPE `("name", "RRGGBB"` (name + 6-hex color),
# NOT "first quoted string on the line", so colon-bearing prose in comments and
# XML docs (`<c>area: security</c>`, `// priority:`) cannot leak in, and a
# structural change to the SSOT yields zero matches and fails loudly.
#
# Usage:
#   extract-declared-labels.sh --iac-dir <github-iac-checkout> [--repo <name>]
#
#   --iac-dir  Root of a github-iac checkout (contains Labels.cs +
#              GovernedRepositories.cs).
#   --repo     Short repo name as declared in GovernedRepositories.cs
#              (e.g. "medley"). Omit for the _core baseline only.
#
# Exit: 0 ok · 2 usage · 3 parse error (SSOT shape changed — fail loudly).
set -euo pipefail

IAC_DIR=""
REPO=""

usage() {
  cat <<'EOF'
extract-declared-labels.sh — emit the declared label names for a repo, derived
at runtime from the github-iac SSOT (_core union the repo's ExtraLabels).

Usage:
  extract-declared-labels.sh --iac-dir <github-iac-checkout> [--repo <name>]

  --iac-dir  Root of a github-iac checkout (Labels.cs + GovernedRepositories.cs).
  --repo     Short repo name in GovernedRepositories.cs; omit for _core only.

Exit: 0 ok · 2 usage · 3 parse error (SSOT shape changed).
EOF
}

die_usage() {
  echo "extract-declared-labels.sh: $1" >&2
  echo "Usage: extract-declared-labels.sh --iac-dir <github-iac-checkout> [--repo <name>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iac-dir)
      IAC_DIR="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$IAC_DIR" ]] || die_usage "--iac-dir is required"
LABELS_CS="$IAC_DIR/Labels.cs"
REPOS_CS="$IAC_DIR/GovernedRepositories.cs"
[[ -f "$LABELS_CS" ]] || die_usage "Labels.cs not found under --iac-dir: $LABELS_CS"

# Pull label names from a stream of C# lines by tuple shape.
tuple_names() {
  grep -oE '\("[^"]+", *"[0-9a-fA-F]{6}"' | sed -E 's/^\("([^"]+)".*/\1/'
}

# _core baseline: the single array between `_core =` and its closing `];`.
# pipefail is toggled off around the grep|sed: a no-match grep exits 1 and would
# otherwise abort the run — emptiness is handled by the guard below, not by set -e.
set +o pipefail
core=$(sed -n '/_core[[:space:]]*=/,/^[[:space:]]*\];/p' "$LABELS_CS" | tuple_names)
set -o pipefail
if [[ -z "$core" ]]; then
  echo "::error::extract-declared-labels: no _core tuples found in $LABELS_CS — SSOT shape changed (fail-closed)." >&2
  exit 3
fi

extra=""
if [[ -n "$REPO" ]]; then
  [[ -f "$REPOS_CS" ]] || die_usage "GovernedRepositories.cs not found under --iac-dir: $REPOS_CS"
  # Isolate the repo's ExtraLabels array: within the target spec only, capture
  # everything between its `ExtraLabels:` marker and the closing `]` — including
  # tuples inline on the marker line (`ExtraLabels: [ ("x", ...) ]`) and on the
  # closing line, with text past the `]` dropped so nothing bleeds into the next
  # spec. Every `new("` line re-scopes `inspec` (1 only when it is the target),
  # so a target with NO ExtraLabels yields nothing. → declared = _core.
  extra_block=$(awk -v repo="$REPO" '
    /new\("/ { inspec = ($0 ~ ("new\\(\"" repo "\"")) ? 1 : 0 }
    inspec && /ExtraLabels[[:space:]]*:/ {
      line = $0
      sub(/.*ExtraLabels[[:space:]]*:/, "", line)
      if (line ~ /\]/) { sub(/\].*/, "", line); print line; next }
      print line
      inextra = 1
      next
    }
    inextra {
      if ($0 ~ /\]/) { line = $0; sub(/\].*/, "", line); print line; inextra = 0; next }
      print
    }
  ' "$REPOS_CS")
  set +o pipefail
  extra=$(printf '%s\n' "$extra_block" | tuple_names)
  set -o pipefail

  # A spec that was NOT found at all is a caller error worth failing on: the
  # requested repo does not exist in the SSOT, so any drift verdict would be
  # meaningless. (Found-but-no-ExtraLabels is fine and yields _core only.)
  if ! grep -qE "new\\(\"$REPO\"" "$REPOS_CS"; then
    echo "::error::extract-declared-labels: repo '$REPO' not found in $REPOS_CS (fail-closed)." >&2
    exit 3
  fi
fi

printf '%s\n' "$core" "$extra" | grep -v '^[[:space:]]*$' | sort -u
