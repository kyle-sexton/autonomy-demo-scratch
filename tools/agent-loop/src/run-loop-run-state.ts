import type { CompletionGateResult } from "./completion-gates.js";
import type { ContainerProbeResult } from "./container-probe.js";
import type { IterationHookReport } from "./hook-observability.js";
import type { TokenUsageLine } from "./run-console.js";
import type { CompletionResult } from "./types.js";

export interface IterationSummaryRow {
  readonly iteration: number;
  readonly elapsedMs: number;
  readonly sentinel: string | null;
  readonly exitCode: number | null;
}

export interface RunLoopRunState {
  iterationRows: IterationSummaryRow[];
  hookReports: IterationHookReport[];
  lastGateResult: CompletionGateResult;
  lastCompletionDecision: CompletionResult;
  lastUsage?: TokenUsageLine;
  containerProbeResult?: ContainerProbeResult;
}

export function createRunLoopRunState(
  initialGate: CompletionGateResult,
  initialDecision: CompletionResult,
): RunLoopRunState {
  return {
    hookReports: [],
    iterationRows: [],
    lastCompletionDecision: initialDecision,
    lastGateResult: initialGate,
  };
}
