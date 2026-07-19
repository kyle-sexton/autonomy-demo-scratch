import type { AgentOutputFormat } from "./session-types.js";

/** Input to an {@link AgentCliAdapter} for one iteration. */
export interface IterationContext {
  readonly containerImage: string;
  readonly hostWorkspacePath: string;
  readonly containerWorkspacePath: string;
  readonly prompt: string;
  readonly resolvedModelSlug?: string;
  readonly outputFormat?: AgentOutputFormat;
  readonly iterationLabel: string;
}

/**
 * Tool-specific container command (Adapter output).
 * Pure: env var **names** only — orchestrator forwards `-e NAME` from host env.
 */
export interface ContainerInvocation {
  readonly requiredEnv: readonly string[];
  readonly command: readonly string[];
  readonly requiresCredential: boolean;
}

/** GoF Adapter: maps {@link IterationContext} → {@link ContainerInvocation}. */
export type AgentCliAdapter = (ctx: IterationContext) => ContainerInvocation;
