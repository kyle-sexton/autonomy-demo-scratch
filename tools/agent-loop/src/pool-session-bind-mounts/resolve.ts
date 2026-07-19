import type { AgentPool } from "../agent-pool.js";
import type { AgentCliKind, WorkspaceBindMount } from "../types.js";
import { resolveClaudePoolSessionBindMounts } from "./claude.js";
import { resolveCodexPoolSessionBindMounts } from "./codex.js";
import { resolveCursorPoolSessionBindMounts } from "./cursor.js";
import { resolveGrokPoolSessionBindMounts } from "./grok.js";
import type { PoolSessionBindMountContext, PoolSessionBindMountResolver } from "./types.js";

const RESOLVERS: Readonly<Record<AgentCliKind, PoolSessionBindMountResolver>> = {
  cursor: resolveCursorPoolSessionBindMounts,
  claude: resolveClaudePoolSessionBindMounts,
  codex: resolveCodexPoolSessionBindMounts,
  grok: resolveGrokPoolSessionBindMounts,
};

/** Per-CLI session bind mounts (hook suppression, future native overrides). */
export function resolvePoolSessionBindMounts(
  pool: AgentPool,
  context: PoolSessionBindMountContext,
): readonly WorkspaceBindMount[] {
  const resolver = RESOLVERS[pool.cli];
  return resolver(pool, context);
}
