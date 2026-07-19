import type { CompletionResult, Sentinel } from "./types.js";

export interface CompletionInput {
  readonly sentinel: Sentinel | null;
  /** True when the backlog files all exist on disk (filesystem ground truth). */
  readonly fsComplete: boolean;
  /** True when this iteration created at least one new backlog file. */
  readonly progressed: boolean;
  /** Headless agent CLI exited non-zero — stop for operator review (no auto-continue). */
  readonly agentFailed?: boolean;
  readonly agentExitCode?: number | null;
}

/**
 * Decide what to do after one iteration, consulting BOTH the sentinel and the
 * filesystem ground truth (Brief acceptance #2).
 *
 * The filesystem is authoritative for `done`: the loop is complete only when the
 * backlog files actually exist. The sentinel adds the false-completion guard — a
 * NO_MORE_TASKS claim while the backlog is incomplete is STUCK, never DONE.
 */
export function decideCompletion(input: CompletionInput): CompletionResult {
  const { sentinel, fsComplete, progressed, agentFailed, agentExitCode } = input;

  if (agentFailed === true) {
    const codeLabel = agentExitCode === null ? "null" : String(agentExitCode);
    return {
      decision: "failed",
      mismatch: false,
      reason: `agent process exited ${codeLabel}; sentinel ignored — stop for operator review (do not auto-continue)`,
    };
  }

  if (fsComplete) {
    // Filesystem is ground truth: the backlog is done. A clean done agrees with
    // the sentinel; any other sentinel is a logged mismatch (still done — fs is
    // authoritative — but the disagreement is worth surfacing).
    const mismatch = sentinel !== "NO_MORE_TASKS";
    return {
      decision: "done",
      mismatch,
      reason: mismatch
        ? `backlog complete on disk; sentinel=${sentinel ?? "<none>"} (mismatch — fs is authoritative)`
        : "backlog complete on disk and sentinel=NO_MORE_TASKS (both signals agree)",
    };
  }

  // From here the backlog is NOT complete on disk.
  if (sentinel === "NO_MORE_TASKS") {
    // LOAD-BEARING false-completion guard: the agent claims done, but the backlog
    // is incomplete on disk. Never DONE — abort as stuck.
    return {
      decision: "stuck",
      mismatch: true,
      reason: "sentinel=NO_MORE_TASKS but backlog incomplete on disk (false completion — aborting)",
    };
  }

  if (progressed) {
    return {
      decision: "continue",
      mismatch: false,
      reason: `progress made this iteration; sentinel=${sentinel ?? "<none>"} — continue with fresh context`,
    };
  }

  return {
    decision: "stuck",
    mismatch: false,
    reason: `no progress this iteration; sentinel=${sentinel ?? "<none>"} — stuck`,
  };
}
