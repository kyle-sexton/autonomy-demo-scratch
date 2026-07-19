/**
 * Strategy bundle for per-CLI extension points (Open/Closed).
 * New CLI = register strategies in module init — inject {@link defaultCliExtensionStrategies} or a test double.
 */

import { selectAdapter } from "./adapters/index.js";
import type { AgentPool } from "./agent-pool.js";
import { resolvePoolAdapter } from "./agent-pool.js";
import { resolveModelSlug } from "./model-profiles/resolve.js";
import type { AgentRunProfile } from "./model-profiles/types.js";
import { selectOutputParser } from "./output-parsers/select.js";
import type { AgentOutputParser } from "./output-parsers/types.js";
import { runIterationPreflight } from "./preflight/run-iteration-preflight.js";
import type { Result } from "./result.js";
import type { AgentCliAdapter, AgentCliKind, AgentOutputFormat } from "./types.js";

/** GoF Strategy — maps tool-agnostic profile to vendor model slug. */
export type ModelSlugStrategy = (
  cli: AgentCliKind,
  profile: AgentRunProfile,
  envOverride?: string,
) => string;

/** GoF Strategy — parses one iteration's agent output. */
export type OutputParserStrategy = (
  cli: AgentCliKind,
  outputFormat: AgentOutputFormat | undefined,
) => AgentOutputParser;

/** GoF Strategy — prompt validation before Docker spend. */
export type IterationPreflightStrategy = (cli: AgentCliKind, prompt: string) => Result<void>;

/** GoF Strategy — container argv for one headless CLI. */
export type AdapterStrategy = (cli: AgentCliKind) => AgentCliAdapter;

/** GoF Strategy — adapter for a resolved pool row. */
export type PoolAdapterStrategy = (pool: Pick<AgentPool, "cli">) => AgentCliAdapter;

/**
 * Injectable strategy surface for {@link runAgentLoop}.
 * Keeps the loop closed for modification, open for new CLIs via registry rows.
 */
export interface CliExtensionStrategies {
  readonly selectAdapter: AdapterStrategy;
  readonly resolvePoolAdapter: PoolAdapterStrategy;
  readonly resolveModelSlug: ModelSlugStrategy;
  readonly selectOutputParser: OutputParserStrategy;
  readonly runIterationPreflight: IterationPreflightStrategy;
}

export const defaultCliExtensionStrategies: CliExtensionStrategies = {
  selectAdapter,
  resolvePoolAdapter,
  resolveModelSlug,
  selectOutputParser,
  runIterationPreflight,
};
