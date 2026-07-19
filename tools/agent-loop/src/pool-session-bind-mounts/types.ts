import type { AgentPool } from "../agent-pool.js";
import type { WorkspaceBindMount } from "../types.js";

export interface PoolSessionBindMountContext {
  readonly workspaceRoot: string;
  readonly agentLoopProjectRoot: string;
  readonly runId: string;
}

export type PoolSessionBindMountResolver = (
  pool: AgentPool,
  context: PoolSessionBindMountContext,
) => readonly WorkspaceBindMount[];
