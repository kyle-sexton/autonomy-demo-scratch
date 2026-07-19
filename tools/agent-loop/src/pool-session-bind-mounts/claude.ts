import type { AgentPool } from "../agent-pool.js";
import type { PoolSessionBindMountContext, PoolSessionBindMountResolver } from "./types.js";

/** Claude pool uses native `.claude/settings.json` hooks when enabled — no session overrides today. */
export const resolveClaudePoolSessionBindMounts: PoolSessionBindMountResolver = (
  _pool: AgentPool,
  _context: PoolSessionBindMountContext,
) => [];
