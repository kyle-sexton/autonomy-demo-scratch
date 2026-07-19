import type { AgentCliKind } from "../types.js";
import { resolveClaudeModelSlug } from "./claude.js";
import { resolveCodexModelSlug } from "./codex.js";
import { resolveCursorModelSlug } from "./cursor.js";
import { resolveGrokModelSlug } from "./grok.js";
import type { AgentRunProfile, CliModelResolver } from "./types.js";

const CLI_MODEL_RESOLVERS: Record<AgentCliKind, CliModelResolver> = {
  cursor: resolveCursorModelSlug,
  claude: resolveClaudeModelSlug,
  codex: resolveCodexModelSlug,
  grok: resolveGrokModelSlug,
};

/**
 * Resolve a vendor model slug for one tool from a tool-agnostic profile.
 * Precedence: env override → explicit `model` in profile → role → effort (+thinking) → CLI default.
 */
export function resolveModelSlug(
  cli: AgentCliKind,
  profile: AgentRunProfile,
  envOverride?: string,
): string {
  if (envOverride !== undefined && envOverride.trim() !== "") {
    return envOverride.trim();
  }
  if (profile.model !== undefined && profile.model.trim() !== "") {
    return profile.model.trim();
  }
  const resolver = CLI_MODEL_RESOLVERS[cli];
  if (resolver === undefined) {
    throw new Error(`No model profile mapping for CLI "${cli}". Set profile.model explicitly.`);
  }
  return resolver(profile);
}
