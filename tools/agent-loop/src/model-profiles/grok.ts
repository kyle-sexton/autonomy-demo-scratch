import type { AgentRunProfile, EffortTier, ImplementRole } from "./types.js";

const ROLE_MODELS: Record<ImplementRole, string> = {
  mechanical: "grok-build",
  implement: "composer-2.5",
  deep: "composer-2.5",
};

const EFFORT_MODELS: Record<EffortTier, string> = {
  low: "grok-build",
  medium: "composer-2.5",
  high: "composer-2.5",
  "extra-high": "composer-2.5",
};

export function resolveGrokModelSlug(profile: AgentRunProfile): string {
  if (profile.role !== undefined) {
    return ROLE_MODELS[profile.role];
  }
  if (profile.effort !== undefined) {
    return EFFORT_MODELS[profile.effort];
  }
  return ROLE_MODELS.implement;
}
