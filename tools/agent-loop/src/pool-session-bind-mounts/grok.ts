import type { AgentPool } from "../agent-pool.js";
import type { PoolSessionBindMountContext, PoolSessionBindMountResolver } from "./types.js";

/** Grok has no medley hook SSOT in pool config — no session bind overrides beyond credential mount. */
export const resolveGrokPoolSessionBindMounts: PoolSessionBindMountResolver = (
  _pool: AgentPool,
  _context: PoolSessionBindMountContext,
) => [];
