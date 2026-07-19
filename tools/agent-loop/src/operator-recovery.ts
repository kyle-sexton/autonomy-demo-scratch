import { ENV } from "./env-keys.js";
import { resolveModelSlug } from "./model-profiles/resolve.js";
import type { AgentCliKind } from "./types.js";

/**
 * Operator-facing recovery context after an agent CLI failure.
 * Built from tool-agnostic inputs — vendor slugs come from {@link resolveModelSlug}.
 */
export interface FailureRecoveryGuide {
  readonly agentCli: AgentCliKind;
  readonly modelUsed: string;
  /** Suggested lower-cost profile for this CLI (`role: "mechanical"`). Not auto-applied. */
  readonly mechanicalRoleModelSlug: string;
}

/** Resolve retry hints for operator discussion — orchestrator never applies them automatically. */
export function buildFailureRecoveryGuide(
  agentCli: AgentCliKind,
  resolvedModelSlug: string,
): FailureRecoveryGuide {
  return {
    agentCli,
    modelUsed: resolvedModelSlug,
    mechanicalRoleModelSlug: resolveModelSlug(agentCli, { role: "mechanical" }),
  };
}

/** Canonical env var for explicit model override (first alias in {@link ENV.model}). */
export function modelOverrideEnvVarName(): string {
  return ENV.model[0];
}
