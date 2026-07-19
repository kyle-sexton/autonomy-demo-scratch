import type { InContainerHooks } from "./agent-pool.js";
import { buildCapabilitiesResolved, loadCapabilityProfile } from "./capabilities/load-profile.js";
import { LOG_PREFIX } from "./constants.js";
import {
  type ContainerProbeResult,
  formatContainerProbeWarnings,
  runContainerEnvironmentProbe,
} from "./container-probe.js";
import type { ContainerRuntime } from "./container-runtime.js";
import {
  analyzeHookFailuresFromToolCallsContent,
  buildIterationHookReport,
  formatHookObservabilityLog,
  type IterationHookReport,
} from "./hook-observability.js";
import { containerProbePath, iterationHookReportPath } from "./iteration-artifacts.js";
import type { RunLoopPorts } from "./ports.js";
import type { WorkspaceBindMount } from "./types.js";

export interface PersistHookReportInput {
  readonly ports: RunLoopPorts;
  readonly logsDirectory: string;
  readonly iteration: number;
  readonly iterLabel: string;
  readonly toolLines: readonly string[];
  readonly logLine: (text: string) => void;
  readonly inContainerHooks?: InContainerHooks;
}

export function persistHookReportFromToolCalls(
  input: PersistHookReportInput,
): IterationHookReport | undefined {
  if (input.toolLines.length === 0) {
    return undefined;
  }
  const toolCallsContent = `${input.toolLines.join("\n")}\n`;
  const hookFailures = analyzeHookFailuresFromToolCallsContent(toolCallsContent, {
    ...(input.inContainerHooks !== undefined ? { inContainerHooks: input.inContainerHooks } : {}),
  });
  const hookReport = buildIterationHookReport(input.iteration, input.iterLabel, hookFailures);
  input.ports.filesystem.writeTextFile(
    iterationHookReportPath(input.logsDirectory, input.iterLabel),
    `${JSON.stringify(hookReport, null, 2)}\n`,
  );
  const hookLog = formatHookObservabilityLog(hookReport);
  if (hookLog.length > 0) {
    input.logLine(hookLog);
  }
  return hookReport;
}

export interface RunContainerProbeInput {
  readonly containerRuntime: ContainerRuntime;
  readonly image: string;
  readonly hostWorkspacePath: string;
  readonly containerWorkspacePath: string;
  readonly runId: string;
  readonly logsDirectory: string;
  readonly ports: RunLoopPorts;
  readonly logLine: (text: string) => void;
  readonly additionalBindMounts?: readonly WorkspaceBindMount[];
  readonly additionalContainerEnv?: Readonly<Record<string, string>>;
  readonly capabilityProfileId: string;
  readonly agentLoopProjectRoot: string;
  readonly inContainerHooks?: InContainerHooks;
}

function enrichContainerProbeResult(
  result: ContainerProbeResult,
  capabilityProfileId: string,
  agentLoopProjectRoot: string,
): ContainerProbeResult {
  const profile = loadCapabilityProfile(capabilityProfileId, agentLoopProjectRoot);
  const observedDependencies: Record<string, boolean> = {};
  for (const dep of result.dependencies ?? []) {
    observedDependencies[dep.name] = dep.present;
  }
  const gitBridge = result.gitBridge ?? {
    layout: "none",
    mode: "unavailable",
    gitStatusExit: null,
  };
  return {
    ...result,
    gitBridge,
    capabilitiesResolved: buildCapabilitiesResolved({
      profile,
      gitBridgeLayout: gitBridge.layout,
      gitBridgeMode: gitBridge.mode,
      gitStatusExit: gitBridge.gitStatusExit,
      observedDependencies,
    }),
  };
}

export async function runAndPersistContainerProbe(
  input: RunContainerProbeInput,
): Promise<ContainerProbeResult | undefined> {
  try {
    const rawProbeResult = await runContainerEnvironmentProbe({
      containerRuntime: input.containerRuntime,
      image: input.image,
      hostWorkspacePath: input.hostWorkspacePath,
      containerWorkspacePath: input.containerWorkspacePath,
      agentLoopProjectRoot: input.agentLoopProjectRoot,
      runId: input.runId,
      ...(input.additionalBindMounts !== undefined
        ? { additionalBindMounts: input.additionalBindMounts }
        : {}),
      ...(input.additionalContainerEnv !== undefined
        ? { additionalContainerEnv: input.additionalContainerEnv }
        : {}),
    });
    const containerProbeResult = enrichContainerProbeResult(
      rawProbeResult,
      input.capabilityProfileId,
      input.agentLoopProjectRoot,
    );
    input.ports.filesystem.writeTextFile(
      containerProbePath(input.logsDirectory),
      `${JSON.stringify(containerProbeResult, null, 2)}\n`,
    );
    input.logLine(
      `${LOG_PREFIX} container probe written: ${containerProbePath(input.logsDirectory)}`,
    );
    for (const warning of formatContainerProbeWarnings(containerProbeResult, {
      ...(input.inContainerHooks !== undefined ? { inContainerHooks: input.inContainerHooks } : {}),
    })) {
      input.logLine(`${LOG_PREFIX} ${warning}`);
    }
    return containerProbeResult;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const containerProbeResult: ContainerProbeResult = {
      schemaVersion: 1,
      error: `probe_failed: ${message}`,
      probeExitCode: null,
    };
    input.ports.filesystem.writeTextFile(
      containerProbePath(input.logsDirectory),
      `${JSON.stringify(containerProbeResult, null, 2)}\n`,
    );
    input.logLine(`${LOG_PREFIX} container probe failed: ${message}`);
    return containerProbeResult;
  }
}
