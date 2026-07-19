import type { AgentRunProfile, EffortTier, ImplementRole } from "./types.js";

/** Default implement model when role/effort omitted (Tier-0: `cursor-agent --list-models`). AFK should set explicit `model` via `route-for-surface.sh`. */
export const CURSOR_DEFAULT_IMPLEMENT_MODEL = "composer-2.5-fast";

const ROLE_MODELS: Record<ImplementRole, string> = {
  mechanical: "composer-2.5-fast",
  implement: "composer-2.5-fast",
  deep: "claude-opus-4-8-thinking-xhigh",
};

const EFFORT_MODELS: Record<EffortTier, string> = {
  low: "claude-opus-4-8-low",
  medium: "claude-opus-4-8-medium",
  high: "claude-opus-4-8-high",
  "extra-high": "claude-opus-4-8-xhigh",
};

const EFFORT_THINKING_MODELS: Record<EffortTier, string> = {
  low: "claude-opus-4-8-thinking-low",
  medium: "claude-opus-4-8-thinking-medium",
  high: "claude-opus-4-8-thinking-high",
  "extra-high": "claude-opus-4-8-thinking-xhigh",
};

export function resolveCursorModelSlug(profile: AgentRunProfile): string {
  if (profile.role !== undefined) {
    return ROLE_MODELS[profile.role];
  }
  if (profile.effort !== undefined) {
    return profile.thinking === true
      ? EFFORT_THINKING_MODELS[profile.effort]
      : EFFORT_MODELS[profile.effort];
  }
  return CURSOR_DEFAULT_IMPLEMENT_MODEL;
}
