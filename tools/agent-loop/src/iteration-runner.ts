import {
  ITERATION_COMPLETION_GRACE_MS,
  ITERATION_IDLE_TIMEOUT_MS,
  ITERATION_MAX_WALL_CLOCK_MS,
} from "./constants.js";
import type { ContainerRuntime, ContainerRuntimeRunOptions } from "./container-runtime.js";
import { buildDockerRunIdentity } from "./docker-run.js";
import { formatIterationLabel } from "./iteration-artifacts.js";
import type { TimeoutKillReason } from "./iteration-timeout.js";
import type {
  AgentCliAdapter,
  ContainerInvocation,
  IterationContext,
  RunSession,
} from "./types.js";

export interface IterationRunInput {
  readonly session: RunSession;
  readonly iteration: number;
  readonly prompt: string;
  readonly adapter: AgentCliAdapter;
  readonly containerRuntime: ContainerRuntime;
  readonly runtimeOptions?: ContainerRuntimeRunOptions;
}

export interface IterationRunOutput {
  readonly log: string;
  readonly elapsedMs: number;
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly killReason: TimeoutKillReason | null;
  /** Idle or wall-clock kill — run-loop may still succeed via fs-before-abort. */
  readonly watchdogTriggered: boolean;
  /** Sentinel seen and completion grace expired while process hung — successful iteration end. */
  readonly completionGraceEnd: boolean;
  readonly containerName: string;
  readonly iterLabel: string;
  readonly containerImage: string;
  readonly dockerLabels: Readonly<Record<string, string>>;
}

/** Single responsibility: one container iteration (spawn + collect output). */
export async function runSingleIteration(input: IterationRunInput): Promise<IterationRunOutput> {
  const { session, iteration, prompt, adapter, containerRuntime, runtimeOptions } = input;
  const iterLabel = formatIterationLabel(iteration, session.agentCli);
  const identity = buildDockerRunIdentity({
    cli: session.agentCli,
    workspacePath: session.hostWorkspacePath,
    runId: session.runId,
    iteration,
    iterLabel,
  });

  const ctx: IterationContext = {
    containerImage: session.containerImage,
    hostWorkspacePath: session.hostWorkspacePath,
    containerWorkspacePath: session.containerWorkspaceMount,
    prompt,
    iterationLabel: iterLabel,
    resolvedModelSlug: session.resolvedModelSlug,
    ...(session.outputFormat !== undefined ? { outputFormat: session.outputFormat } : {}),
  };

  const inv: ContainerInvocation = adapter(ctx);

  const outcome = await containerRuntime.run(
    {
      image: session.containerImage,
      name: identity.containerName,
      labels: identity.labels,
      workspaceHostPath: ctx.hostWorkspacePath,
      workspaceContainerPath: ctx.containerWorkspacePath,
      envVarNames: inv.requiredEnv,
      command: inv.command,
      idleTimeoutMs: ITERATION_IDLE_TIMEOUT_MS,
      maxWallClockMs: ITERATION_MAX_WALL_CLOCK_MS,
      completionGraceMs: ITERATION_COMPLETION_GRACE_MS,
      ...(session.outputFormat !== undefined ? { outputFormat: session.outputFormat } : {}),
      ...(session.additionalBindMounts !== undefined
        ? { additionalBindMounts: session.additionalBindMounts }
        : {}),
      ...(session.additionalContainerEnv !== undefined
        ? { additionalContainerEnv: session.additionalContainerEnv }
        : {}),
      ...(session.containerRunUser !== undefined ? { runAsUser: session.containerRunUser } : {}),
    },
    runtimeOptions,
  );

  const log = `${outcome.stdout}${outcome.stderr}`;
  const completionGraceEnd = outcome.killReason === "completion-grace";
  const watchdogTriggered = outcome.killReason === "idle" || outcome.killReason === "wall-clock";

  return {
    log,
    elapsedMs: outcome.elapsedMs,
    exitCode: outcome.exitCode,
    signal: outcome.signal,
    killReason: outcome.killReason,
    watchdogTriggered,
    completionGraceEnd,
    containerName: identity.containerName,
    iterLabel,
    containerImage: session.containerImage,
    dockerLabels: identity.labels,
  };
}
