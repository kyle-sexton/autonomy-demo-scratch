import type { AgentRunProfile, EffortTier, ImplementRole } from "./types.js";

/** Opus 4.8 era — Tier-0: `claude --help` / release notes (align with cursor.ts role map). */
const ROLE_MODELS: Record<ImplementRole, string> = {
  mechanical: "claude-haiku-4-5",
  implement: "claude-sonnet-4-6",
  deep: "claude-opus-4-8",
};

const EFFORT_MODELS: Record<EffortTier, string> = {
  low: "claude-sonnet-4-6",
  medium: "claude-sonnet-4-6",
  high: "claude-opus-4-8",
  "extra-high": "claude-opus-4-8",
};

export function resolveClaudeModelSlug(profile: AgentRunProfile): string {
  if (profile.role !== undefined) {
    return ROLE_MODELS[profile.role];
  }
  if (profile.effort !== undefined) {
    return EFFORT_MODELS[profile.effort];
  }
  return ROLE_MODELS.implement;
}
