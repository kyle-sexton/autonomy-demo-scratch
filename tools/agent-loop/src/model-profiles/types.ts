/**
 * Tool-agnostic model selection vocabulary.
 * Vendor slug tables live in per-CLI modules under this folder.
 */

export type EffortTier = "low" | "medium" | "high" | "extra-high";

export type ImplementRole = "mechanical" | "implement" | "deep";

/** Subset of {@link RunLocalConfig} used for model resolution. */
export interface AgentRunProfile {
  readonly model?: string;
  readonly role?: ImplementRole;
  readonly effort?: EffortTier;
  readonly thinking?: boolean;
}

/** Maps a tool-agnostic profile to one vendor model slug for a specific CLI. */
export type CliModelResolver = (profile: AgentRunProfile) => string;
