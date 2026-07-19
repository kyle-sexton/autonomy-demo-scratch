import { join } from "node:path";

import { resolveAgentPool } from "./agent-pool.js";
import { decideCompletion } from "./completion.js";
import { evaluateCompletionGates } from "./completion-gates.js";
import { LOG_PREFIX } from "./constants.js";
import { workspaceSlugFromPath } from "./docker-run.js";
import { ORCHESTRATOR_LOG_FILENAME } from "./iteration-artifacts.js";
import { loadPoolsLocalConfig } from "./pools-config.js";
import { defaultRunLoopPorts, type RunLoopPorts } from "./ports.js";
import {
  assertCredentialsPresent,
  assertPoolHostCredentialsPresent,
} from "./preflight/credentials.js";
import { assertHostContainerEnvBoundary } from "./preflight/host-container-env-boundary.js";
import {
  assertHostGitConfigBoundary,
  repairHostGitConfigBoundary,
} from "./preflight/host-git-config-boundary.js";
import { formatRunBanner, type TokenUsageLine } from "./run-console.js";
import {
  createDefaultRunLoopDependencies,
  type RunLoopDependencies,
} from "./run-loop-dependencies.js";
import { finalizeAgentLoopRun, resolveAbortReason } from "./run-loop-finalize.js";
import { executeAgentLoopIteration } from "./run-loop-iteration.js";
import { runAndPersistContainerProbe } from "./run-loop-observability.js";
import { createRunLoopRunState } from "./run-loop-run-state.js";
import type { IterationContext, RunSession } from "./types.js";
import { captureGitSnapshot, type GitSnapshot } from "./workspace-snapshot.js";

export interface RunAgentLoopOptions {
  readonly session: RunSession;
  readonly projectRoot: string;
  readonly ports?: RunLoopPorts;
  /** Strategy bundle + container runtime (DIP). Defaults to production registries. */
  readonly dependencies?: RunLoopDependencies;
}

function buildInitialCompletionDecision(
  gateResult: ReturnType<typeof evaluateCompletionGates>,
): ReturnType<typeof decideCompletion> {
  return decideCompletion({
    sentinel: null,
    fsComplete: gateResult.fsComplete,
    progressed: false,
  });
}

/**
 * Runs the bounded iteration loop.
 * Depends on {@link RunLoopPorts} (dependency inversion) — defaults to Node/Docker.
 */
// biome-ignore lint/complexity/noExcessiveLinesPerFunction: orchestrator coordinates pool resolve, preflight, and iteration loop
export async function runAgentLoop(options: RunAgentLoopOptions): Promise<never> {
  const {
    session,
    projectRoot,
    ports = defaultRunLoopPorts,
    dependencies = createDefaultRunLoopDependencies(),
  } = options;
  const { strategies, containerRuntime } = dependencies;
  const {
    maxIterations,
    promptPath,
    hostWorkspacePath,
    completionOutSubdir,
    completionTarget,
    completionFile,
    blockedFile,
    selfCheckFile,
    hostVerifyScript,
    runId,
    resolvedModelSlug,
    logsDirectory,
    agentCli,
    containerImage,
    containerWorkspaceMount,
    outputFormat,
  } = session;

  ports.filesystem.ensureDirectory(hostWorkspacePath);
  ports.filesystem.ensureDirectory(logsDirectory);

  const gateConfig = {
    workspaceRoot: hostWorkspacePath,
    completionOutSubdir,
    completionTarget,
    ...(completionFile !== undefined ? { completionFile } : {}),
    ...(blockedFile !== undefined ? { blockedFile } : {}),
    ...(selfCheckFile !== undefined ? { selfCheckFile } : {}),
  };

  const prompt = ports.filesystem.readTextFile(promptPath);
  const pool = resolveAgentPool(session.poolId, projectRoot, loadPoolsLocalConfig(projectRoot));
  const adapter = strategies.resolvePoolAdapter(pool);
  const outputParser = strategies.selectOutputParser(agentCli, outputFormat);
  const workspaceSlug = workspaceSlugFromPath(hostWorkspacePath);
  const runLogPath = join(logsDirectory, ORCHESTRATOR_LOG_FILENAME);
  const gitBefore: GitSnapshot = captureGitSnapshot(hostWorkspacePath);

  const logLine = (text: string): void => {
    ports.console.log(text);
    ports.filesystem.appendTextFile(runLogPath, text);
  };

  const promptPreflight = strategies.runIterationPreflight(agentCli, prompt);
  if (!promptPreflight.ok) {
    ports.console.error(`${LOG_PREFIX} ${promptPreflight.error.message}`);
    ports.exit.exit(promptPreflight.error.exitCode);
  }

  logLine(
    formatRunBanner({
      runId,
      tool: agentCli,
      workspacePath: hostWorkspacePath,
      workspaceSlug,
      promptPath,
      target: completionTarget,
      outSubdir: completionOutSubdir,
      cap: maxIterations,
      runLogPath,
      model: resolvedModelSlug,
      ...(completionFile !== undefined ? { completionFile } : {}),
      ...(hostVerifyScript !== undefined ? { hostVerifyScript } : {}),
    }),
  );

  const preflightContext: IterationContext = {
    containerImage,
    hostWorkspacePath,
    containerWorkspacePath: containerWorkspaceMount,
    prompt,
    iterationLabel: "preflight",
  };
  assertHostContainerEnvBoundary({ env: process.env, ports });
  repairHostGitConfigBoundary({
    hostWorkspacePath,
    env: process.env,
    logLine,
  });
  assertHostGitConfigBoundary({
    hostWorkspacePath,
    env: process.env,
    ports,
  });
  assertCredentialsPresent({
    pool,
    preflightContext,
    env: process.env,
    projectRoot,
    ports,
  });
  assertPoolHostCredentialsPresent({ pool, projectRoot, ports });

  const sessionBindMountCount = session.additionalBindMounts?.length ?? 0;
  if (sessionBindMountCount > 0) {
    logLine(
      `${LOG_PREFIX} session bind mounts: ${String(sessionBindMountCount)} (pool ${pool.id}, inContainerHooks=${pool.inContainerHooks})`,
    );
  }

  const containerProbeResult = await runAndPersistContainerProbe({
    containerRuntime,
    image: containerImage,
    hostWorkspacePath,
    containerWorkspacePath: containerWorkspaceMount,
    runId,
    logsDirectory,
    ports,
    logLine,
    inContainerHooks: pool.inContainerHooks,
    ...(session.additionalBindMounts !== undefined
      ? { additionalBindMounts: session.additionalBindMounts }
      : {}),
    ...(session.additionalContainerEnv !== undefined
      ? { additionalContainerEnv: session.additionalContainerEnv }
      : {}),
    capabilityProfileId: session.capabilityProfileId,
    agentLoopProjectRoot: projectRoot,
  });

  const initialGate = evaluateCompletionGates(gateConfig, 0, 0);
  const initialDecision = buildInitialCompletionDecision(initialGate);
  const state = createRunLoopRunState(initialGate, initialDecision);
  if (containerProbeResult !== undefined) {
    state.containerProbeResult = containerProbeResult;
  }

  const finalizeEarly = (
    finalExitCode: number,
    runHostVerify: boolean,
    abortReason?: string,
  ): never =>
    finalizeAgentLoopRun(state, {
      session,
      ports,
      logLine,
      runLogPath,
      logsDirectory,
      iteration: 0,
      gateResult: initialGate,
      completionDecision: initialDecision,
      gitBefore,
      finalExitCode,
      runHostVerify,
      ...(abortReason !== undefined ? { abortReason } : {}),
    });

  if (initialGate.blockedPresent) {
    logLine(`${LOG_PREFIX} pre-loop gate: ${initialGate.reason} — skipping agent iterations.`);
    finalizeEarly(3, false, initialGate.reason);
  }

  if (initialGate.fsComplete) {
    logLine(`${LOG_PREFIX} pre-loop gate: ${initialGate.reason} — backlog already complete.`);
    finalizeEarly(0, true);
  }

  for (let iter = 1; iter <= maxIterations; iter++) {
    // biome-ignore lint/performance/noAwaitInLoops: agent loop runs one container iteration at a time by design.
    const outcome = await executeAgentLoopIteration({
      iter,
      maxIterations,
      session,
      prompt,
      adapter,
      containerRuntime,
      gateConfig,
      ports,
      logsDirectory,
      runLogPath,
      logLine,
      outputParser,
      inContainerHooks: pool.inContainerHooks,
      state,
      hostWorkspacePath,
      containerWorkspaceMount,
      completionOutSubdir,
      completionTarget,
      ...(completionFile !== undefined ? { completionFile } : {}),
      resolvedModelSlug,
    });

    if (outcome.kind === "terminal") {
      finalizeAgentLoopRun(state, {
        session,
        ports,
        logLine,
        runLogPath,
        logsDirectory,
        iteration: iter,
        gateResult: outcome.gateResult,
        completionDecision: outcome.completionDecision,
        gitBefore,
        finalExitCode: outcome.finalExitCode,
        runHostVerify: outcome.runHostVerify,
        ...(outcome.finalExitCode !== 0
          ? { abortReason: resolveAbortReason(outcome.finalExitCode) }
          : {}),
      });
    }
  }

  ports.console.error(
    `${LOG_PREFIX} hit iteration cap (${maxIterations}) without completing the backlog.`,
  );
  ports.filesystem.appendTextFile(runLogPath, `run incomplete · cap=${maxIterations}`);
  finalizeAgentLoopRun(state, {
    session,
    ports,
    logLine,
    runLogPath,
    logsDirectory,
    iteration: maxIterations,
    gateResult: state.lastGateResult,
    completionDecision: state.lastCompletionDecision,
    gitBefore,
    finalExitCode: 4,
    abortReason: `iteration cap (${maxIterations}) without completing backlog`,
    runHostVerify: false,
    ...(state.lastUsage !== undefined ? { lastUsage: state.lastUsage as TokenUsageLine } : {}),
  });
}
