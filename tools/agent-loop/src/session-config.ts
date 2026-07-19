import { existsSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";

import { type AgentPool, resolveAgentPool, resolvePoolAdditionalBindMounts } from "./agent-pool.js";
import { resolveClaudeContainerRunUser } from "./claude-headless-config.js";
import { inferBlockedFileFromCompletion, validateCompletionGatePaths } from "./completion-gates.js";
import { CONTAINER_WORKSPACE_MOUNT, TOY_COMPLETION_TARGET, TOY_PROMPT_PATH } from "./constants.js";
import { resolveContainerRunUser } from "./container-user.js";
import { createRunId, resolveRunLogsDirectory, workspaceSlugFromPath } from "./docker-run.js";
import { ENV, readEnv } from "./env-keys.js";
import { normalizeHostFilesystemPath } from "./host-path.js";
import { loadPoolsLocalConfig } from "./pools-config.js";
import {
  loadRunLocalConfig,
  resolveMaxIterations,
  resolveModelForTool,
  resolveOutputFormat,
} from "./run-config.js";
import { resolveSessionContainerSetup } from "./session-container-setup.js";
import { evaluateSpendGateOrError } from "./spend-gate.js";
import type { RunSession } from "./types.js";
import { resolveRepoRelativePath } from "./workspace-snapshot.js";

export interface SessionConfigInput {
  readonly projectRoot: string;
  readonly cwd: string;
  readonly argv: readonly string[];
  readonly defaultWorkspacePath: string;
  /** Optional test override — otherwise resolved from the selected pool. */
  readonly gateMarkerPath?: string;
}

export type SessionBuildResult =
  | { readonly ok: true; readonly session: RunSession; readonly poolId: string }
  | { readonly ok: false; readonly exitCode: number; readonly message: string };

type SessionBuildFailure = Extract<SessionBuildResult, { ok: false }>;

function isSessionBuildFailure(result: unknown): result is SessionBuildFailure {
  return (
    typeof result === "object" &&
    result !== null &&
    "ok" in result &&
    (result as { ok: unknown }).ok === false &&
    "exitCode" in result
  );
}

export function resolveWorkspacePath(
  raw: string | undefined,
  cwd: string,
  defaultPath: string,
): string {
  if (raw === undefined || raw.trim() === "") {
    return defaultPath;
  }
  const trimmed = raw.trim();
  const resolved = isAbsolute(trimmed) ? trimmed : resolve(cwd, trimmed);
  return normalizeHostFilesystemPath(resolved);
}

export function resolvePromptPath(raw: string | undefined, projectRoot: string): string {
  const promptFile = raw ?? TOY_PROMPT_PATH;
  const resolved = isAbsolute(promptFile) ? promptFile : resolve(projectRoot, promptFile);
  return normalizeHostFilesystemPath(resolved);
}

function resolveSelectedPoolId(
  runLocalPoolId: string | undefined,
  envPoolId: string | undefined,
  poolsConfig: ReturnType<typeof loadPoolsLocalConfig>,
): string | undefined {
  if (envPoolId !== undefined && envPoolId.trim() !== "") {
    return envPoolId.trim();
  }
  if (runLocalPoolId !== undefined && runLocalPoolId.trim() !== "") {
    return runLocalPoolId.trim();
  }
  return poolsConfig.defaultPoolId;
}

function loadRunLocalConfigOrError(
  projectRoot: string,
): SessionBuildFailure | ReturnType<typeof loadRunLocalConfig> {
  try {
    return loadRunLocalConfig(projectRoot);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, exitCode: 1, message };
  }
}

function loadPoolsConfigOrError(
  projectRoot: string,
): SessionBuildFailure | ReturnType<typeof loadPoolsLocalConfig> {
  try {
    return loadPoolsLocalConfig(projectRoot);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, exitCode: 1, message };
  }
}

function resolvePoolOrError(
  projectRoot: string,
  poolsConfig: ReturnType<typeof loadPoolsLocalConfig>,
  runLocal: ReturnType<typeof loadRunLocalConfig>,
): SessionBuildFailure | AgentPool {
  try {
    return resolveAgentPool(
      resolveSelectedPoolId(runLocal.poolId, readEnv(ENV.pool), poolsConfig),
      projectRoot,
      poolsConfig,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, exitCode: 1, message };
  }
}

interface ContainerSetupInput {
  readonly pool: AgentPool;
  readonly hostWorkspacePath: string;
  readonly projectRoot: string;
  readonly runId: string;
  readonly credentialMounts: ReturnType<typeof resolvePoolAdditionalBindMounts>;
}

function resolveContainerSetupOrError(
  input: ContainerSetupInput,
): SessionBuildFailure | ReturnType<typeof resolveSessionContainerSetup> {
  try {
    return resolveSessionContainerSetup({
      pool: input.pool,
      hostWorkspacePath: input.hostWorkspacePath,
      agentLoopProjectRoot: input.projectRoot,
      runId: input.runId,
      credentialMounts: input.credentialMounts,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      exitCode: 1,
      message: `Failed to prepare session container setup: ${message}`,
    };
  }
}

function resolveCompletionTarget(argv: readonly string[]): number {
  const targetRaw = argv[4] ?? readEnv(ENV.completionTarget);
  const targetArg = Number.parseInt(targetRaw ?? "", 10);
  return Number.isFinite(targetArg) && targetArg > 0 ? targetArg : TOY_COMPLETION_TARGET;
}

interface SessionBootstrap {
  readonly runLocal: ReturnType<typeof loadRunLocalConfig>;
  readonly poolsConfig: ReturnType<typeof loadPoolsLocalConfig>;
  readonly pool: AgentPool;
}

function loadSessionBootstrap(projectRoot: string): SessionBuildFailure | SessionBootstrap {
  const runLocalResult = loadRunLocalConfigOrError(projectRoot);
  if (isSessionBuildFailure(runLocalResult)) {
    return runLocalResult;
  }
  const poolsConfigResult = loadPoolsConfigOrError(projectRoot);
  if (isSessionBuildFailure(poolsConfigResult)) {
    return poolsConfigResult;
  }
  const poolResult = resolvePoolOrError(projectRoot, poolsConfigResult, runLocalResult);
  if (isSessionBuildFailure(poolResult)) {
    return poolResult;
  }
  return { runLocal: runLocalResult, poolsConfig: poolsConfigResult, pool: poolResult };
}

function validateSessionGatePaths(input: {
  readonly workspaceRoot: string;
  readonly completionFile?: string;
  readonly blockedFile?: string;
  readonly selfCheckFile?: string;
  readonly hostVerifyScript?: string;
}): SessionBuildFailure | undefined {
  try {
    validateCompletionGatePaths({
      workspaceRoot: input.workspaceRoot,
      ...(input.completionFile !== undefined ? { completionFile: input.completionFile } : {}),
      ...(input.blockedFile !== undefined ? { blockedFile: input.blockedFile } : {}),
      ...(input.selfCheckFile !== undefined ? { selfCheckFile: input.selfCheckFile } : {}),
    });
    if (input.hostVerifyScript !== undefined && input.hostVerifyScript.trim() !== "") {
      resolveRepoRelativePath({
        workspaceRoot: input.workspaceRoot,
        relativePath: input.hostVerifyScript,
      });
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, exitCode: 1, message };
  }
  return undefined;
}

export function buildRunSession(input: SessionConfigInput): SessionBuildResult {
  const {
    projectRoot,
    cwd,
    argv,
    defaultWorkspacePath,
    gateMarkerPath: gateMarkerOverride,
  } = input;
  const bootstrap = loadSessionBootstrap(projectRoot);
  if (isSessionBuildFailure(bootstrap)) {
    return bootstrap;
  }
  const { runLocal, poolsConfig, pool } = bootstrap;

  const capArg = Number.parseInt(argv[2] ?? "", 10);
  const cliCap = Number.isFinite(capArg) && capArg > 0 ? capArg : undefined;
  const completionTarget = resolveCompletionTarget(argv);
  const promptPath = resolvePromptPath(argv[3] ?? readEnv(ENV.prompt), projectRoot);
  if (!existsSync(promptPath)) {
    return { ok: false, exitCode: 1, message: `Prompt file not found: ${promptPath}` };
  }
  const hostWorkspacePath = resolveWorkspacePath(
    argv[5] ?? readEnv(ENV.workspace),
    cwd,
    defaultWorkspacePath,
  );
  const completionOutSubdir = readEnv(ENV.outSubdir) ?? "out";
  const workspaceSlug = workspaceSlugFromPath(hostWorkspacePath);
  const runId = createRunId(new Date(), readEnv(ENV.runId), workspaceSlug);
  const maxIterations = resolveMaxIterations(runLocal, cliCap, readEnv(ENV.maxIterations));
  const resolvedModelSlug = resolveModelForTool(pool.cli, runLocal, readEnv(ENV.model));
  const logsDirectory = resolveRunLogsDirectory(projectRoot, runId, readEnv(ENV.logDirectory));
  const credentialMounts = resolvePoolAdditionalBindMounts(pool, projectRoot, poolsConfig);
  const containerSetupResult = resolveContainerSetupOrError({
    pool,
    hostWorkspacePath,
    projectRoot,
    runId,
    credentialMounts,
  });
  if (isSessionBuildFailure(containerSetupResult)) {
    return containerSetupResult;
  }
  const { additionalBindMounts, additionalContainerEnv } = containerSetupResult;
  const containerRunUser =
    pool.cli === "claude"
      ? resolveClaudeContainerRunUser(hostWorkspacePath)
      : resolveContainerRunUser(hostWorkspacePath);

  const gateError = evaluateSpendGateOrError(pool, projectRoot, poolsConfig, gateMarkerOverride);
  if (gateError !== undefined) {
    return { ok: false, exitCode: gateError.exitCode, message: gateError.message };
  }

  const completionFile = readEnv(ENV.completionFile);
  const selfCheckFile = readEnv(ENV.selfCheckFile);
  const blockedFileExplicit = readEnv(ENV.blockedFile);
  const blockedFile =
    blockedFileExplicit ??
    (completionFile !== undefined ? inferBlockedFileFromCompletion(completionFile) : undefined);
  const hostVerifyScript = readEnv(ENV.hostVerifyScript);

  const gatePathError = validateSessionGatePaths({
    workspaceRoot: hostWorkspacePath,
    ...(completionFile !== undefined ? { completionFile } : {}),
    ...(blockedFile !== undefined ? { blockedFile } : {}),
    ...(selfCheckFile !== undefined ? { selfCheckFile } : {}),
    ...(hostVerifyScript !== undefined ? { hostVerifyScript } : {}),
  });
  if (gatePathError !== undefined) {
    return gatePathError;
  }

  const session: RunSession = {
    poolId: pool.id,
    agentCli: pool.cli,
    containerImage: pool.containerImage,
    containerWorkspaceMount: CONTAINER_WORKSPACE_MOUNT,
    maxIterations,
    promptPath,
    hostWorkspacePath,
    completionOutSubdir,
    completionTarget,
    runId,
    resolvedModelSlug,
    logsDirectory,
    outputFormat: resolveOutputFormat(runLocal),
    ...(completionFile !== undefined ? { completionFile } : {}),
    ...(blockedFile !== undefined ? { blockedFile } : {}),
    ...(selfCheckFile !== undefined ? { selfCheckFile } : {}),
    ...(hostVerifyScript !== undefined ? { hostVerifyScript } : {}),
    capabilityProfileId: pool.capabilityProfileId,
    ...(additionalBindMounts.length > 0 ? { additionalBindMounts } : {}),
    ...(Object.keys(additionalContainerEnv).length > 0 ? { additionalContainerEnv } : {}),
    ...(containerRunUser !== undefined ? { containerRunUser } : {}),
  };

  return { ok: true, session, poolId: pool.id };
}
