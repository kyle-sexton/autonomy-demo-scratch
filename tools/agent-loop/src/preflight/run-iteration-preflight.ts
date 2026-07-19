import type { Result } from "../result.js";
import { successVoid } from "../result.js";
import type { AgentCliKind } from "../types.js";
import { validateCursorPromptByteBudget } from "./cursor-prompt-budget.js";
import type { IterationPreflightChecker } from "./types.js";

const ITERATION_PREFLIGHT: Partial<Record<AgentCliKind, IterationPreflightChecker>> = {
  cursor: validateCursorPromptByteBudget,
};

/** Run per-CLI prompt preflight before Docker spend. No-op when a CLI has no checker. */
export function runIterationPreflight(cli: AgentCliKind, prompt: string): Result<void> {
  const checker = ITERATION_PREFLIGHT[cli];
  if (checker === undefined) {
    return successVoid();
  }
  return checker(prompt);
}
