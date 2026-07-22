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
WITH rows AS (
  SELECT *
  FROM read_json_auto('__JOIN_PATH__', format = 'newline_delimited')
  WHERE fire_kind = 'scheduled'
    AND fire_attested = true
    AND completed_at::TIMESTAMP >= '__WINDOW_START__'::TIMESTAMP
)
SELECT
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
