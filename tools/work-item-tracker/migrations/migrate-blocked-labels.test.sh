#!/usr/bin/env bash
# Tests for migrate-blocked-labels.sh — the pure logic (blocker parsing, the
# label-absence sanity discipline, and the claim-state classifier). The gh-touching
# apply/verify paths are exercised only against the sandbox/live tracker under the
# gated post-merge run (README.md); they mutate shared coordination state and so are
# never unit-tested here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=migrate-blocked-labels.sh
source "$SCRIPT_DIR/migrate-blocked-labels.sh"
# shellcheck source=../../../tests/shell/lib.sh
source "$REPO_ROOT/tests/shell/lib.sh"

FAILED=0

# --- mbl_parse_depends_on -------------------------------------------------

OUT="$(printf '%s' 'Part of map #1369. Depends on: #1479 (deploy that creates the repo).' | mbl_parse_depends_on)"
assert_eq "single internal ref" "internal:1479" "$OUT"

OUT="$(printf '%s\n%s\n' '**Live gate: Depends on: #1393** (repo missing).' 'this issue is blocked on #1393 and executable once it closes.' | mbl_parse_depends_on)"
assert_eq "markdown-wrapped ref, deduped across lines" "internal:1393" "$OUT"

OUT="$(printf 'Depends on: #1307\nDepends on: #1308\nDepends on: #1379\n' | mbl_parse_depends_on)"
assert_eq "multiline depends-on lines" "internal:1307
internal:1308
internal:1379" "$OUT"

OUT="$(printf '%s' 'Depends on: #10, #20 and #30' | mbl_parse_depends_on)"
assert_eq "comma-separated refs on one line" "internal:10
internal:20
internal:30" "$OUT"

OUT="$(printf '%s' 'Depends on: upstream gh release 2.94' | mbl_parse_depends_on)"
assert_eq "external blocker reified verbatim" "external:upstream gh release 2.94" "$OUT"

OUT="$(printf '%s' 'A normal issue body with no dependency lines at all.' | mbl_parse_depends_on)"
assert_eq "no depends-on yields empty" "" "$OUT"

# --- mbl_absence_verdict (R14/R4 crux) -----------------------------------

V="$(
  mbl_absence_verdict 1 '[{"name":"status: ready"}]' '"status: blocked"'
  echo "rc=$?"
)"
assert_contains "provider fetch failure is ERROR, never clean" "$V" "ERROR"
assert_contains "provider fetch failure returns code 2" "$V" "rc=2"

V="$(
  mbl_absence_verdict 0 '[{"name":"status: blocked"},{"name":"status: ready"}]' '"status: blocked"'
  echo "rc=$?"
)"
assert_contains "label still present is PRESENT" "$V" "PRESENT"
assert_contains "label present returns code 1" "$V" "rc=1"

V="$(
  mbl_absence_verdict 0 '[{"name":"status: ready"},{"name":"needs-human"}]' '"status: blocked"'
  echo "rc=$?"
)"
assert_contains "clean fetch with label absent is ABSENT" "$V" "ABSENT"
assert_contains "label absent returns code 0" "$V" "rc=0"

# --- mbl_claim_state (in-flight crux: live-lease-aware, newest event wins) --

# Fixture epochs around renewed_at 2026-01-01T00:00:00Z (epoch 1767225600), ttl 24h.
LEASE_RENEWED_EPOCH=1767225600
NOW_WITHIN_TTL=$((LEASE_RENEWED_EPOCH + 3600))
NOW_PAST_TTL=$((LEASE_RENEWED_EPOCH + 25 * 3600))

LEASE_LIVE='<!-- work-item-lease v1 {"schema_version":"1.0","holder":"w1","acquired_at":"2026-01-01T00:00:00Z","renewed_at":"2026-01-01T00:00:00Z","ttl_hours":24} -->'
LEASE_SUPERSEDED='<!-- work-item-lease v1 {"schema_version":"1.0","holder":"w2","acquired_at":"2026-01-01T00:00:00Z","renewed_at":"2026-01-01T00:00:00Z","ttl_hours":24,"superseded_at":"2026-01-01T00:30:00Z"} -->'
RECLAIM_NOTE='work-item-lease reclaimed: lease expired (renewed_at 2026-01-01T00:00:00Z) with no activity.'

# pages <body>@<id>… — emit a single --paginate --slurp page of comments.
pages() {
  local rows=() entry
  for entry in "$@"; do
    rows+=("$(jq -cn --arg body "${entry%@*}" --argjson id "${entry##*@}" '{id: $id, body: $body}')")
  done
  printf '[[%s]]' "$(
    IFS=,
    printf '%s' "${rows[*]}"
  )"
}

OUT="$(pages "$LEASE_SUPERSEDED@20" "$RECLAIM_NOTE@30" | mbl_claim_state "$NOW_PAST_TTL")"
assert_eq "reclaimed lease reads released, not claimed-forever" "released" "$OUT"

OUT="$(pages "$LEASE_LIVE@20" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "live lease is claimed" "claimed" "$OUT"

OUT="$(pages "$LEASE_LIVE@20" | mbl_claim_state "$NOW_PAST_TTL")"
assert_eq "expired unreclaimed lease is not a live claim" "released" "$OUT"

OUT="$(pages "$LEASE_LIVE@20" "$LEASE_SUPERSEDED@40" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "newer superseded back-off never masks an earlier live lease" "claimed" "$OUT"

OUT="$(pages "claimed: w1 2026-01-01T01:00:00Z@10" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "textual claim trail is claimed" "claimed" "$OUT"

OUT="$(pages "claimed: w1@10" "released: w1@20" "claimed: w1@30" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "re-claim after release is claimed (newest event wins)" "claimed" "$OUT"

OUT="$(pages "claimed: w1@10" "released: w1@20" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "released textual trail is released" "released" "$OUT"

OUT="$(pages "claimed: w1@10" "$LEASE_SUPERSEDED@20" "$RECLAIM_NOTE@30" | mbl_claim_state "$NOW_PAST_TTL")"
assert_eq "reclaim note outranks an older textual claim" "released" "$OUT"

# Per-worker evaluation (worker-protocol.md: withdrawal is same-id). Another worker's
# back-off must NEVER mask a live claim from a different worker.
OUT="$(pages "claimed: w1 2026-01-01T01:00:00Z@10" "unclaimed: w2@20" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "another worker's unclaimed never masks a live claim" "claimed" "$OUT"

OUT="$(pages "claimed: wA@10" "released: wA@30" "claimed: wB@20" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "wA released but wB still holds an active claim" "claimed" "$OUT"

OUT="$(pages "claimed: w1@10" "released: w1@20" "unclaimed: w2@30" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "all workers withdrawn is released" "released" "$OUT"

OUT="$(pages "$RECLAIM_NOTE@10" "claimed: w1@20" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "a claim re-posted after a reclaim note is live again" "claimed" "$OUT"

OUT="$(pages "claimed: w1@10" "$RECLAIM_NOTE@20" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "reclaim note globally clears an older textual claim" "released" "$OUT"

OUT="$(pages "just a discussion comment@10" | mbl_claim_state "$NOW_WITHIN_TTL")"
assert_eq "no claim trail at all is none" "none" "$OUT"

[[ $FAILED -eq 0 ]] || exit 1
