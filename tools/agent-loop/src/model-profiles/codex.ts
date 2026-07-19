import type { AgentRunProfile, EffortTier, ImplementRole } from "./types.js";

const ROLE_MODELS: Record<ImplementRole, string> = {
  mechanical: "gpt-5.3-codex-spark",
  implement: "gpt-5.3-codex",
  deep: "gpt-5.3-codex-high",
};

const EFFORT_MODELS: Record<EffortTier, string> = {
  low: "gpt-5.3-codex-spark",
  medium: "gpt-5.3-codex",
  high: "gpt-5.3-codex-high",
  "extra-high": "gpt-5.3-codex-high",
};

export function resolveCodexModelSlug(profile: AgentRunProfile): string {
  if (profile.role !== undefined) {
    return ROLE_MODELS[profile.role];
  }
  if (profile.effort !== undefined) {
    return EFFORT_MODELS[profile.effort];
  }
  return ROLE_MODELS.implement;
}
