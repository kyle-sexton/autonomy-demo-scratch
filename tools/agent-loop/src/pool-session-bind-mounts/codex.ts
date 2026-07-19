import type { AgentPool } from "../agent-pool.js";
import type { PoolSessionBindMountContext, PoolSessionBindMountResolver } from "./types.js";

/** Codex has no medley hook SSOT in pool config — no session bind overrides. */
export const resolveCodexPoolSessionBindMounts: PoolSessionBindMountResolver = (
  _pool: AgentPool,
  _context: PoolSessionBindMountContext,
) => [];
