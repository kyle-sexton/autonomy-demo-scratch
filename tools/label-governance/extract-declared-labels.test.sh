#!/usr/bin/env bash
# Tests for extract-declared-labels.sh. Runs against synthetic Labels.cs /
# GovernedRepositories.cs fixtures (hermetic — no dependency on a sibling
# github-iac checkout), covering the shape-anchoring and fail-closed guards.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

EXTRACT="$SCRIPT_DIR/extract-declared-labels.sh"
FAILED=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

IAC="$WORK/iac"
mkdir -p "$IAC"

cat >"$IAC/Labels.cs" <<'CS'
internal static class Labels
{
    private static readonly (string Name, string Color, string Description)[] _core =
    [
        // priority: — urgency. This comment mentions "priority: critical" as prose.
        ("priority: critical", "e51720", "Release blocker."),
        ("area: security", "930023", "Security-relevant <c>area: security</c>."),
        ("automated", "ededed", "Opened by automation."),
    ];
}
CS

cat >"$IAC/GovernedRepositories.cs" <<'CS'
    new("other", a => { a.Visibility = "private"; }),

    new("inline", a => { a.Visibility = "private"; }, ExtraLabels: [ ("inline: one", "111111", "Inline tuple on the marker line.") ]),

    new("medley", a => { a.Visibility = "private"; },
    ExtraLabels:
    [
        ("wayfind: research", "1d76db", "Typed investigation."),
        ("area: ci-cd", "a12f2f", "CI/CD."),
    ],
    VulnerabilityAlerts: true),

    new("medley-archive", a => { a.Visibility = "private"; }, ManagedLabels: false),
CS

# --- _core only ---
out=$(bash "$EXTRACT" --iac-dir "$IAC")
rc=$?
assert_exit "core-only extraction exits 0" 0 "$rc"
assert_contains "core includes priority: critical (colon-space)" "$out" "priority: critical"
assert_contains "core includes area: security" "$out" "area: security"
# Shape anchoring: the prose 'priority: critical' in the comment must not produce
# a duplicate or a stray token — exactly one occurrence, from the tuple.
n=$(printf '%s\n' "$out" | grep -c '^priority: critical$')
assert_eq "no comment/docstring leakage (single tuple hit)" "1" "$n"

# --- core ∪ medley ExtraLabels ---
out=$(bash "$EXTRACT" --iac-dir "$IAC" --repo medley)
rc=$?
assert_exit "medley extraction exits 0" 0 "$rc"
assert_contains "medley adds wayfind: research" "$out" "wayfind: research"
assert_contains "medley adds area: ci-cd" "$out" "area: ci-cd"
assert_contains "medley still carries _core" "$out" "automated"

# --- a repo prefix must not bleed across specs (medley vs medley-archive) ---
assert_not_contains "medley extraction excludes other repos' markers" "$out" "medley-archive"
assert_not_contains "medley extraction excludes the inline spec's ExtraLabels" "$out" "inline: one"

# --- a repo with NO ExtraLabels, ordered BEFORE one that has them, must yield
# _core only (regression: inspec must reset per spec, not leak medley's block) ---
other_out=$(bash "$EXTRACT" --iac-dir "$IAC" --repo other)
assert_contains "no-ExtraLabels repo still carries _core" "$other_out" "priority: critical"
assert_not_contains "no-ExtraLabels repo does NOT inherit the next spec's ExtraLabels" "$other_out" "wayfind: research"
other_n=$(printf '%s\n' "$other_out" | grep -c .)
assert_eq "no-ExtraLabels repo yields exactly _core (3 in fixture)" "3" "$other_n"

# --- inline ExtraLabels on the marker line: tuple captured, closing ] honored
# (regression: the marker-line tuple was dropped and the skipped ] made later
# specs bleed into the target) ---
inline_out=$(bash "$EXTRACT" --iac-dir "$IAC" --repo inline)
rc=$?
assert_exit "inline-ExtraLabels extraction exits 0" 0 "$rc"
assert_contains "inline marker-line tuple is captured" "$inline_out" "inline: one"
assert_not_contains "inline close does NOT bleed into the next spec's ExtraLabels" "$inline_out" "wayfind: research"
assert_contains "inline repo still carries _core" "$inline_out" "automated"

# --- fail-closed: unknown repo ---
rc=$(
  bash "$EXTRACT" --iac-dir "$IAC" --repo ghost >/dev/null 2>&1
  echo $?
)
assert_exit "unknown repo fails closed (3)" 3 "$rc"

# --- fail-closed: _core shape changed (no tuples) ---
BADIAC="$WORK/bad"
mkdir -p "$BADIAC"
printf 'internal static class Labels { }\n' >"$BADIAC/Labels.cs"
rc=$(
  bash "$EXTRACT" --iac-dir "$BADIAC" >/dev/null 2>&1
  echo $?
)
assert_exit "missing _core tuples fails closed (3)" 3 "$rc"

# --- usage: missing --iac-dir ---
rc=$(
  bash "$EXTRACT" >/dev/null 2>&1
  echo $?
)
assert_exit "missing --iac-dir exits usage(2)" 2 "$rc"

# --- --help contract: exit 0 + non-empty stdout ---
help_out=$(bash "$EXTRACT" --help 2>/dev/null)
help_rc=$?
assert_exit "--help exits 0" 0 "$help_rc"
assert_contains "--help prints usage" "$help_out" "Usage:"

[[ $FAILED -eq 0 ]] || exit 1
echo "OK: extract-declared-labels.sh tests passed"
