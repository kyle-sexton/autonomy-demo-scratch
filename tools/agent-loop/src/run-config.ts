import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { DEFAULT_OUTPUT_FORMAT } from "./constants.js";
import { resolveModelSlug } from "./model-profiles/resolve.js";
import type { AgentRunProfile, EffortTier, ImplementRole } from "./model-profiles/types.js";
import type { AgentCliKind, AgentOutputFormat } from "./types.js";

export const RUN_CONFIG_FILENAME = "run.local.json";

export const RUN_CONFIG_EXAMPLE_FILENAME = "run.example.json";

export const DEFAULT_MAX_ITERATIONS = 6;

export interface RunLocalConfig extends AgentRunProfile {
  /** Max agent iterations for one orchestrator invocation — not concurrent runs. */
  readonly maxIterations?: number;
  readonly outputFormat?: "text" | "json" | "stream-json";
  /** Built-in pool id from pools.example.jsonc (e.g. cursor-default). */
  readonly poolId?: string;
}

const EFFORT_TIERS: readonly EffortTier[] = ["low", "medium", "high", "extra-high"];
const IMPLEMENT_ROLES: readonly ImplementRole[] = ["mechanical", "implement", "deep"];

function isEffortTier(value: string): value is EffortTier {
  return (EFFORT_TIERS as readonly string[]).includes(value);
}

function isImplementRole(value: string): value is ImplementRole {
  return (IMPLEMENT_ROLES as readonly string[]).includes(value);
}

export function parseRunLocalConfig(raw: string): RunLocalConfig {
  const parsed = JSON.parse(raw) as RunLocalConfig;
  return {
    ...(typeof parsed.model === "string" && parsed.model.length > 0 ? { model: parsed.model } : {}),
    ...(typeof parsed.role === "string" && isImplementRole(parsed.role)
      ? { role: parsed.role }
      : {}),
    ...(typeof parsed.effort === "string" && isEffortTier(parsed.effort)
      ? { effort: parsed.effort }
      : {}),
    ...(parsed.thinking === true ? { thinking: true } : {}),
    ...(typeof parsed.maxIterations === "number" &&
    Number.isFinite(parsed.maxIterations) &&
    parsed.maxIterations > 0
      ? { maxIterations: Math.floor(parsed.maxIterations) }
      : {}),
    ...(parsed.outputFormat === "text" ||
    parsed.outputFormat === "json" ||
    parsed.outputFormat === "stream-json"
      ? { outputFormat: parsed.outputFormat }
      : {}),
    ...(typeof parsed.poolId === "string" && parsed.poolId.trim() !== ""
      ? { poolId: parsed.poolId.trim() }
      : {}),
  };
}

export class RunLocalConfigError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "RunLocalConfigError";
  }
}

/** Load gitignored `run.local.json` when present; returns `{}` when absent. */
export function loadRunLocalConfig(projectRoot: string): RunLocalConfig {
  const path = join(projectRoot, RUN_CONFIG_FILENAME);
  if (!existsSync(path)) {
    return {};
  }
  try {
    return parseRunLocalConfig(readFileSync(path, "utf8"));
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new RunLocalConfigError(
      `Invalid ${RUN_CONFIG_FILENAME} at ${path}: ${detail}. Fix JSON syntax or remove the file to use defaults.`,
      { cause: error },
    );
  }
}

export function resolveModelForTool(
  cli: AgentCliKind,
  runConfig: RunLocalConfig,
  envOverride?: string,
): string {
  return resolveModelSlug(cli, runConfig, envOverride);
}

/**
 * Max iterations per run. Precedence: CLI arg → `RALPH_MAX_ITERATIONS` env →
 * `run.local.json` → {@link DEFAULT_MAX_ITERATIONS}.
 */
export function resolveMaxIterations(
  runConfig: RunLocalConfig,
  cliCap?: number,
  envOverride?: string,
): number {
  if (cliCap !== undefined && Number.isFinite(cliCap) && cliCap > 0) {
    return Math.floor(cliCap);
  }
  if (envOverride !== undefined && envOverride.trim() !== "") {
    const fromEnv = Number.parseInt(envOverride.trim(), 10);
    if (Number.isFinite(fromEnv) && fromEnv > 0) {
      return fromEnv;
    }
  }
  if (runConfig.maxIterations !== undefined && runConfig.maxIterations > 0) {
    return runConfig.maxIterations;
  }
  return DEFAULT_MAX_ITERATIONS;
}

/** Precedence: `run.local.json` → {@link DEFAULT_OUTPUT_FORMAT}. */
export function resolveOutputFormat(runConfig: RunLocalConfig): AgentOutputFormat {
  return runConfig.outputFormat ?? DEFAULT_OUTPUT_FORMAT;
}
