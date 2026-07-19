/** Why a tracked spawn was killed (null = process exited on its own). */
export type TimeoutKillReason = "idle" | "wall-clock" | "completion-grace";

export interface IterationTimeoutConfig {
  readonly idleTimeoutMs: number;
  readonly maxWallClockMs: number;
  readonly completionGraceMs: number;
}

export interface TimeoutEvaluationInput {
  readonly elapsedMs: number;
  readonly msSinceLastOutput: number;
  /** Milliseconds since sentinel first appeared (null when no sentinel yet). */
  readonly msSinceSentinel: number | null;
  readonly config: IterationTimeoutConfig;
}

export interface TimeoutEvaluation {
  readonly shouldKill: boolean;
  readonly reason: TimeoutKillReason | null;
  readonly inCompletionGrace: boolean;
}

/**
 * Pure timeout decision for one poll tick.
 * Idle timer resets on output; sentinel switches to completion grace; wall clock is a backstop.
 */
export function evaluateIterationTimeout(input: TimeoutEvaluationInput): TimeoutEvaluation {
  const { elapsedMs, msSinceLastOutput, msSinceSentinel, config } = input;
  const inCompletionGrace = msSinceSentinel !== null;

  if (elapsedMs >= config.maxWallClockMs) {
    return { shouldKill: true, reason: "wall-clock", inCompletionGrace };
  }

  if (msSinceSentinel !== null) {
    if (msSinceSentinel >= config.completionGraceMs) {
      return { shouldKill: true, reason: "completion-grace", inCompletionGrace: true };
    }
    return { shouldKill: false, reason: null, inCompletionGrace: true };
  }

  if (msSinceLastOutput >= config.idleTimeoutMs) {
    return { shouldKill: true, reason: "idle", inCompletionGrace: false };
  }

  return { shouldKill: false, reason: null, inCompletionGrace: false };
}
