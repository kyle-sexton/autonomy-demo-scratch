-- C2 auto-merge promotion-predicate inputs (autonomy-ignition Phase 1 STUB).
--
-- Computes the four evidence inputs the guardrail predicate needs
-- (plugins/autonomy/reference/guardrails/work-classes.md, "C2 auto-merge"):
-- completion count, window span in days, deterministic-gate pass rate, and
-- human-reverted-merge count -- FILTERED to scheduled-fire identity rows, since
-- manual assists never count as autonomous completions.
--
-- Input is the combined per-run join output predicate-c2.sh materializes (one
-- newline-delimited row per completed (item_url, run_id), each the verify-join
-- projection enriched with completed_at). The runner substitutes __JOIN_PATH__
-- and __WINDOW_START__ (DRAIN_WINDOW_START_UTC from drain-common.sh).
--
-- human_revert_count derives from the `reverted` column verify-join populates
-- (the SHA of the commit reverting the merge, or NULL when unreverted).
--
-- Completion maturity: the >=20-completions threshold counts only completions whose
-- PR merged >=48h before evaluation time (predicate-c2.sh enriches each row with a
-- completion_mature boolean via drain_merge_is_mature; the maturity decision is
-- computed in the shell so it stays unit-testable without duckdb). `completions` is
-- the raw attested count and `completions_mature` the count the gate uses; both are
-- surfaced. window_span_days spans the MATURE completions only (the same row set as
-- completions_mature): otherwise a burst of mature completions clustered in a few days
-- plus one young straggler far later would satisfy the count and the span gates on
-- DISJOINT evidence — the exact burst shape the maturity guard exists to block.
--
-- Window bound: the accumulation window opens at the first genuine scheduled fire
-- (DRAIN_WINDOW_START_UTC); warm-up and manual rows completed before it never count.
--
-- Fire origin is NOT taken from the fire_kind stamp (the Desktop task hardcodes
-- --fire-kind, so a manual "Run now" self-stamps as scheduled). predicate-c2.sh
-- attests each run's origin from outer-session transcript evidence and enriches each
-- row with fire_attested; rows that fail attestation (fire_attested = false) are
-- excluded here, fail-closed.
--
-- Delegated pre-merge corrections: the completion definition is claim->implement->PR with
-- NO help, and a run whose PR the verifying session had to fix before merge had help.
-- predicate-c2.sh enriches each row with `corrected` from the operator-maintained
-- run-corrections.jsonl. The exclusion is from the INPUT SET, not from the completion
-- count alone, so EVERY aggregate below -- count, span, gate pass rate, revert count --
-- computes over genuinely autonomous completions only: a repaired run that happened to be
-- the earliest or latest mature completion would otherwise still establish the >=7-day
-- span, opening the gate before seven days of autonomous evidence existed. `corrected =
-- false` (not `IS NOT TRUE`) is deliberate: a NULL makes the predicate false and drops the
-- row, so an unenriched row fails CLOSED.
--
-- Event-driven (labeled) fires: fire_kind = 'labeled' rows carry a kick-verified
-- attestation (attest-fire-origin.sh's relay-run path, scratch#42) but do NOT enter
-- the eligibility input set yet — until the push-capable dispatch hop exists, the
-- labeled attestation path has zero live traffic, and a promotion-critical predicate
-- must not widen onto a never-live-validated path. They are SURFACED instead
-- (labeled CTE below -> completions_labeled_attested), so event-driven completions
-- are visible from the first real fire; activation is the one-line reviewed change
-- `fire_kind IN ('scheduled', 'labeled')` in the rows CTE, at which point every
-- filter and aggregate here applies to them uniformly. 'manual' and unknown kinds
-- stay excluded in both states (the kind filter admits listed values only). The labeled
-- CTE carries the SAME `corrected = false` filter: a corrected run is not an autonomous
-- completion whatever fired it, and the surfaced count would otherwise contradict the
-- eligibility count it previews.
WITH rows AS (
  SELECT *
  FROM read_json_auto('__JOIN_PATH__', format = 'newline_delimited')
  WHERE fire_kind = 'scheduled'
    AND fire_attested = true
    AND corrected = false
    AND completed_at::TIMESTAMP >= '__WINDOW_START__'::TIMESTAMP
),
labeled AS (
  SELECT COUNT(DISTINCT item_url || '#' || run_id) AS n
  FROM read_json_auto('__JOIN_PATH__', format = 'newline_delimited')
  WHERE fire_kind = 'labeled'
    AND fire_attested = true
    AND corrected = false
    AND completed_at::TIMESTAMP >= '__WINDOW_START__'::TIMESTAMP
)
SELECT
  -- informational only until labeled activation (see header): attested event-driven
  -- completions in the window, kept out of every eligibility aggregate below.
  (SELECT n FROM labeled) AS completions_labeled_attested,
  COUNT(DISTINCT item_url || '#' || run_id) AS completions,
  COUNT(DISTINCT CASE WHEN completion_mature THEN item_url || '#' || run_id END)
    AS completions_mature,
  COALESCE(
    DATE_DIFF('day',
      MIN(completed_at::TIMESTAMP) FILTER (WHERE completion_mature),
      MAX(completed_at::TIMESTAMP) FILTER (WHERE completion_mature)),
    0
  ) AS window_span_days,
  -- pass rate over rows that HAVE a gate outcome (AVG skips NULLs); no gates yet -> 0
  COALESCE(
    AVG(CASE WHEN gate_conclusion = 'success' THEN 1.0
             WHEN gate_conclusion IS NULL THEN NULL
             ELSE 0.0 END),
    0.0
  ) AS gate_pass_rate,
  COUNT(*) FILTER (WHERE reverted IS NOT NULL) AS human_revert_count,
  -- eligibility mirrors the suggested default; a NULL/absent gate fails closed. Both
  -- the >=20 count and the >=7-day span are over mature (>=48h-merged) completions only.
  (COUNT(DISTINCT CASE WHEN completion_mature THEN item_url || '#' || run_id END) >= 20
   AND COALESCE(
         DATE_DIFF('day',
           MIN(completed_at::TIMESTAMP) FILTER (WHERE completion_mature),
           MAX(completed_at::TIMESTAMP) FILTER (WHERE completion_mature)),
         0) >= 7
   AND COALESCE(MIN(CASE WHEN gate_conclusion = 'success' THEN 1 ELSE 0 END), 0) = 1
   AND COUNT(*) FILTER (WHERE reverted IS NOT NULL) = 0) AS predicate_eligible
FROM rows;
