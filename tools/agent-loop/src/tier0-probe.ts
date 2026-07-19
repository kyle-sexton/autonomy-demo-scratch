import { existsSync, readFileSync, unlinkSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { AgentPool } from "./agent-pool.js";
import { CONTAINER_WORKSPACE_MOUNT } from "./constants.js";
import { type ContainerRunSpec, createDockerContainerRuntime } from "./container-runtime.js";
import { normalizeHostFilesystemPath } from "./host-path.js";
import { resolveSessionContainerSetup } from "./session-container-setup.js";
import { evaluateSpendGateOrError, loadPoolsConfigForSpendGate } from "./spend-gate.js";
import type { WorkspaceBindMount } from "./types.js";

export const ERROR_EXCERPT_MAX_CHARS = 4000;
export const PROBE_PREVIEW_MAX_CHARS = 200;
export const DEFAULT_MAX_WALL_CLOCK_MS = 180_000;
export const HOOK_BLOCKED_PATTERN = /hook blocked/i;

export function agentLoopProjectRoot(importMetaUrl: string): string {
  return resolve(dirname(fileURLToPath(importMetaUrl)), "..");
}

export function buildTier0Prompt(probeRelative: string): string {
  const containerPath = `${CONTAINER_WORKSPACE_MOUNT}/${probeRelative}`;
  return `Write exactly the line TIER0_OK to the file ${containerPath}. Do not use shell. Reply with DONE when finished.`;
}

export type ResolveWorkspaceRootOptions = {
  readonly normalizePath?: boolean;
};

export function resolveTier0WorkspaceRoot(
  argv: readonly string[],
  projectRoot: string,
  usage: () => void,
  options?: ResolveWorkspaceRootOptions,
): { workspaceRoot: string; skipSpendGate: boolean } {
  let skipSpendGate = false;
  const positional: string[] = [];
  for (const arg of argv.slice(2)) {
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--skip-spend-gate") {
      skipSpendGate = true;
      continue;
    }
    positional.push(arg);
  }
  const workspaceArg = positional[0];
  const rawRoot =
    workspaceArg !== undefined && workspaceArg.trim() !== ""
      ? resolve(workspaceArg.trim())
      : resolve(projectRoot, "../..");
  const workspaceRoot =
    options?.normalizePath === true ? normalizeHostFilesystemPath(rawRoot) : rawRoot;
  return { workspaceRoot, skipSpendGate };
}

export type Tier0RunContext = {
  readonly prompt: string;
  readonly workspaceRoot: string;
  readonly probeHostPath: string;
  readonly containerSetup: ReturnType<typeof resolveSessionContainerSetup>;
};

export type Tier0ProbeParams = {
  readonly pool: AgentPool;
  readonly projectRoot: string;
  readonly workspaceRoot: string;
  readonly skipSpendGate: boolean;
  readonly probeRelative: string;
  readonly passLabel: string;
  readonly tier0RunIdPrefix: string;
  readonly containerNamePrefix: string;
  readonly componentLabel: string;
  readonly maxWallClockMs?: number;
  readonly credentialMounts?: readonly WorkspaceBindMount[];
  readonly preRunAuthCheck?: () => void;
  readonly buildRunSpec: (ctx: Tier0RunContext) => ContainerRunSpec;
  readonly hookBlockedExtra?: (combinedOutput: string) => boolean;
  readonly hookBlockedMessage?: string;
  readonly agentExitLabel?: string;
};

export async function runHeadlessTier0Probe(params: Tier0ProbeParams): Promise<void> {
  const poolsConfig = loadPoolsConfigForSpendGate(params.projectRoot);

  if (!params.skipSpendGate) {
    const gateError = evaluateSpendGateOrError(params.pool, params.projectRoot, poolsConfig);
    if (gateError !== undefined) {
      process.stderr.write(`error: ${gateError.message}\n`);
      process.exit(gateError.exitCode);
    }
  }

  params.preRunAuthCheck?.();

  const tier0RunId = `${params.tier0RunIdPrefix}-${String(Date.now())}`;
  const containerSetup = resolveSessionContainerSetup({
    pool: params.pool,
    hostWorkspacePath: params.workspaceRoot,
    agentLoopProjectRoot: params.projectRoot,
    runId: tier0RunId,
    credentialMounts: params.credentialMounts ?? [],
  });

  const probeHostPath = resolve(params.workspaceRoot, params.probeRelative);
  if (existsSync(probeHostPath)) {
    unlinkSync(probeHostPath);
  }

  const prompt = buildTier0Prompt(params.probeRelative);
  const runSpec = params.buildRunSpec({
    prompt,
    workspaceRoot: params.workspaceRoot,
    probeHostPath,
    containerSetup,
  });

  const runtime = createDockerContainerRuntime();
  const outcome = await runtime.run(runSpec);

  const combinedOutput = `${outcome.stdout}\n${outcome.stderr}`;
  const hookBlocked =
    HOOK_BLOCKED_PATTERN.test(combinedOutput) ||
    (params.hookBlockedExtra?.(combinedOutput) ?? false);

  if (outcome.exitCode !== 0) {
    const agentLabel = params.agentExitLabel ?? "agent";
    process.stderr.write(`error: ${agentLabel} exit ${String(outcome.exitCode)}\n`);
    process.stderr.write(combinedOutput.slice(0, ERROR_EXCERPT_MAX_CHARS));
    process.exit(1);
  }

  if (hookBlocked) {
    process.stderr.write(
      params.hookBlockedMessage ?? "error: hook block detected in tier-0 output\n",
    );
    process.stderr.write(combinedOutput.slice(0, ERROR_EXCERPT_MAX_CHARS));
    process.exit(1);
  }

  if (!existsSync(probeHostPath)) {
    process.stderr.write(`error: probe file missing on host: ${probeHostPath}\n`);
    process.exit(1);
  }

  const content = readFileSync(probeHostPath, "utf8");
  if (!content.includes("TIER0_OK")) {
    process.stderr.write(
      `error: probe file content unexpected: ${content.slice(0, PROBE_PREVIEW_MAX_CHARS)}\n`,
    );
    process.exit(1);
  }

  unlinkSync(probeHostPath);
  process.stdout.write(`${params.passLabel}\n`);
}
