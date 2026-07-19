import { posix } from "node:path";

import type { InContainerHooks } from "./agent-pool.js";
import type { CapabilitiesResolved } from "./capabilities/load-profile.js";
import { AGENT_LOOP_TOOL_CONTAINER_MOUNT, CONTAINER_PROBE_MAX_WALL_CLOCK_MS } from "./constants.js";
import type { ContainerRuntime } from "./container-runtime.js";
import { CONTAINER_PROBE_SCRIPT_CONTAINER_PATH } from "./iteration-artifacts.js";
import type { WorkspaceBindMount } from "./types.js";

export interface ContainerDependencyStatus {
  readonly name: string;
  readonly present: boolean;
  readonly version?: string;
}

export interface ContainerGitBridgeProbe {
  readonly layout: string;
  readonly mode: string;
  readonly gitStatusExit: number | null;
}

export interface ContainerProbeResult {
  readonly schemaVersion: number;
  readonly workspace?: string;
  readonly error?: string;
  readonly dependencies?: readonly ContainerDependencyStatus[];
  readonly gitBridge?: ContainerGitBridgeProbe;
  readonly capabilitiesResolved?: CapabilitiesResolved;
  readonly hookConfig?: {
    readonly hasCursorHooks: boolean;
    readonly hasClaudeSettings: boolean;
    readonly settingsHasHooksKey?: boolean;
    readonly cursorHooksFilePresent?: boolean;
    readonly cursorHooksEmpty?: boolean;
  };
  readonly hookProbe?: {
    readonly script: string;
    readonly exitCode: number | null;
    readonly stderr: string;
  };
  readonly rawStdout?: string;
  readonly rawStderr?: string;
  readonly probeExitCode: number | null;
}

export interface ContainerProbeInput {
  readonly containerRuntime: ContainerRuntime;
  readonly image: string;
  readonly hostWorkspacePath: string;
  readonly containerWorkspacePath: string;
  readonly agentLoopProjectRoot: string;
  readonly runId: string;
  readonly additionalBindMounts?: readonly WorkspaceBindMount[];
  readonly additionalContainerEnv?: Readonly<Record<string, string>>;
}

function parseProbeJson(stdout: string): ContainerProbeResult {
  const trimmed = stdout.trim();
  if (trimmed === "") {
    return {
      schemaVersion: 1,
      error: "empty_probe_stdout",
      probeExitCode: null,
    };
  }
  try {
    const parsed = JSON.parse(trimmed) as ContainerProbeResult;
    return { ...parsed, probeExitCode: 0 };
  } catch {
    return {
      schemaVersion: 1,
      error: "invalid_probe_json",
      rawStdout: trimmed.slice(0, 4000),
      probeExitCode: null,
    };
  }
}

/** Run the container environment probe once before the agent loop starts. */
export async function runContainerEnvironmentProbe(
  input: ContainerProbeInput,
): Promise<ContainerProbeResult> {
  const scriptPath = posix.join(
    AGENT_LOOP_TOOL_CONTAINER_MOUNT,
    CONTAINER_PROBE_SCRIPT_CONTAINER_PATH,
  );
  const toolBindMount: WorkspaceBindMount = {
    hostPath: input.agentLoopProjectRoot,
    containerPath: AGENT_LOOP_TOOL_CONTAINER_MOUNT,
    readOnly: true,
  };
  const bindMounts = [...(input.additionalBindMounts ?? []), toolBindMount];
  const outcome = await input.containerRuntime.run(
    {
      image: input.image,
      name: `agent-loop-probe-${input.runId}`,
      labels: {
        "agent-loop.run-id": input.runId,
        "agent-loop.component": "container-probe",
      },
      workspaceHostPath: input.hostWorkspacePath,
      workspaceContainerPath: input.containerWorkspacePath,
      envVarNames: [],
      command: ["bash", scriptPath],
      idleTimeoutMs: CONTAINER_PROBE_MAX_WALL_CLOCK_MS,
      maxWallClockMs: CONTAINER_PROBE_MAX_WALL_CLOCK_MS,
      completionGraceMs: 0,
      additionalBindMounts: bindMounts,
      ...(Object.keys(input.additionalContainerEnv ?? {}).length > 0
        ? { additionalContainerEnv: input.additionalContainerEnv }
        : {}),
    },
    undefined,
  );

  const parsed = parseProbeJson(outcome.stdout);
  return {
    ...parsed,
    ...(outcome.stderr.length > 0 ? { rawStderr: outcome.stderr } : {}),
    probeExitCode: outcome.exitCode,
  };
}

export interface FormatContainerProbeWarningsOptions {
  readonly inContainerHooks?: InContainerHooks;
}

export function formatContainerProbeWarnings(
  result: ContainerProbeResult,
  options: FormatContainerProbeWarningsOptions = {},
): string[] {
  const warnings: string[] = [];

  if (result.error !== undefined) {
    warnings.push(`container probe error: ${result.error}`);
    return warnings;
  }

  const requiredForHooks = ["jq", "bash", "git"];
  for (const name of requiredForHooks) {
    const dep = result.dependencies?.find((entry) => entry.name === name);
    if (dep === undefined || !dep.present) {
      warnings.push(`container probe: missing dependency "${name}" (hooks may silently fail)`);
    }
  }

  if (options.inContainerHooks === "suppressed") {
    const hookConfig = result.hookConfig;
    if (hookConfig?.settingsHasHooksKey === true) {
      warnings.push(
        "container probe: effective .claude/settings.json still has hooks key — session suppression may have failed",
      );
    }
    if (hookConfig?.cursorHooksFilePresent === true && hookConfig.cursorHooksEmpty !== true) {
      warnings.push(
        "container probe: .cursor/hooks.json is present and non-empty — session suppression may have failed",
      );
    }
  }

  const hookProbeStderr = result.hookProbe?.stderr;
  // biome-ignore lint/suspicious/noUnnecessaryConditions: hookProbe is optional, so hookProbeStderr is string|undefined; the ?. is required by tsc. Biome's type engine drops the undefined from the optional-chain result.
  if (hookProbeStderr?.includes("jq") === true) {
    warnings.push(
      `container probe: hook dry-run stderr mentions jq — ${hookProbeStderr.slice(0, 200)}`,
    );
  }

  const gitBridge = result.gitBridge;
  if (gitBridge !== undefined && gitBridge.mode === "unavailable") {
    warnings.push("container probe: git bridge unavailable — in-container git status/mv will fail");
  }
  if (
    gitBridge !== undefined &&
    gitBridge.gitStatusExit !== null &&
    gitBridge.gitStatusExit !== 0
  ) {
    warnings.push(
      `container probe: git status exit ${String(gitBridge.gitStatusExit)} with bridge active`,
    );
  }

  return warnings;
}
