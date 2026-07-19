import { existsSync } from "node:fs";

import type { AgentPool } from "../agent-pool.js";
import { resolvePoolAdapter } from "../agent-pool.js";
import { claudeMeteredOverrideMessage } from "../claude-headless-config.js";
import { LOG_PREFIX } from "../constants.js";
import { credentialSetupHint, missingEnvVars } from "../env.js";
import { resolvePoolBindMountHostPath } from "../pools-config.js";
import type { RunLoopPorts } from "../ports.js";
import type { IterationContext } from "../types.js";

/**
 * Credential preflight — fails fast before any Docker spend.
 * Uses adapter-declared env vars (via {@link resolvePoolAdapter}).
 */
export function assertCredentialsPresent(params: {
  readonly pool: AgentPool;
  readonly preflightContext: IterationContext;
  readonly env: NodeJS.ProcessEnv;
  readonly projectRoot: string;
  readonly ports: RunLoopPorts;
}): void {
  const inv = resolvePoolAdapter(params.pool)(params.preflightContext);
  const missing = missingEnvVars(inv.requiredEnv, params.env);
  if (params.pool.cli === "claude") {
    const meteredMessage = claudeMeteredOverrideMessage(params.env);
    if (meteredMessage !== undefined) {
      params.ports.console.error(`${LOG_PREFIX} ${meteredMessage}.`);
      params.ports.exit.exit(5);
    }
  }
  if (missing.length === 0) {
    return;
  }
  params.ports.console.error(
    `${LOG_PREFIX} required credential env not set — refusing launch (would hang on auth).`,
  );
  params.ports.console.error(`${LOG_PREFIX} ${credentialSetupHint(params.projectRoot, missing)}`);
  params.ports.exit.exit(5);
}

/** Fail fast when a pool requires host credential files (e.g. Codex auth.json). */
export function assertPoolHostCredentialsPresent(params: {
  readonly pool: AgentPool;
  readonly projectRoot: string;
  readonly ports: RunLoopPorts;
}): void {
  const requiredPaths = params.pool.requiredHostPaths ?? [];
  const missing = requiredPaths.filter(
    (path) => !existsSync(resolvePoolBindMountHostPath(path, params.projectRoot)),
  );
  if (missing.length === 0) {
    return;
  }
  params.ports.console.error(
    `${LOG_PREFIX} required credential file(s) missing for pool "${params.pool.id}" — refusing launch.`,
  );
  for (const path of missing) {
    params.ports.console.error(`${LOG_PREFIX}   missing: ${path}`);
  }
  params.ports.exit.exit(5);
}
