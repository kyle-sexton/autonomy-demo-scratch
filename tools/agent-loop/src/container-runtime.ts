import { spawn } from "node:child_process";

import { buildDockerRunArgs } from "./docker-run.js";
import type { TimeoutKillReason } from "./iteration-timeout.js";
import { defaultTrackedSpawnClock, runTrackedSpawn, type TrackedSpawnFn } from "./tracked-spawn.js";
import type { AgentOutputFormat, WorkspaceBindMount } from "./types.js";

export interface ContainerRunSpec {
  readonly image: string;
  readonly name: string;
  readonly labels: Readonly<Record<string, string>>;
  readonly workspaceHostPath: string;
  readonly workspaceContainerPath: string;
  readonly envVarNames: readonly string[];
  readonly command: readonly string[];
  readonly additionalBindMounts?: readonly WorkspaceBindMount[];
  readonly additionalContainerEnv?: Readonly<Record<string, string>>;
  readonly idleTimeoutMs: number;
  readonly maxWallClockMs: number;
  readonly completionGraceMs: number;
  readonly runAsUser?: string;
  readonly outputFormat?: AgentOutputFormat;
}

export interface ContainerRunResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly elapsedMs: number;
  readonly killReason: TimeoutKillReason | null;
}

export interface ContainerRuntimeRunOptions {
  readonly onOutputChunk?: (chunk: string, stream: "stdout" | "stderr") => void;
}

export interface ContainerRuntime {
  readonly id: "docker" | "podman";
  run(spec: ContainerRunSpec, options?: ContainerRuntimeRunOptions): Promise<ContainerRunResult>;
}

export function createDockerContainerRuntime(
  spawnTracked: TrackedSpawnFn = spawn,
): ContainerRuntime {
  return {
    id: "docker",
    run: (spec, options) => runDockerContainer(spec, spawnTracked, options?.onOutputChunk),
  };
}

async function runDockerContainer(
  spec: ContainerRunSpec,
  spawnTracked: TrackedSpawnFn,
  onOutputChunk?: (chunk: string, stream: "stdout" | "stderr") => void,
): Promise<ContainerRunResult> {
  const dockerArgs = buildDockerRunArgs({
    image: spec.image,
    containerName: spec.name,
    workspaceHostPath: spec.workspaceHostPath,
    workspaceContainerPath: spec.workspaceContainerPath,
    requiredEnv: spec.envVarNames,
    command: spec.command,
    labels: spec.labels,
    ...(spec.additionalBindMounts !== undefined
      ? { additionalBindMounts: spec.additionalBindMounts }
      : {}),
    ...(spec.additionalContainerEnv !== undefined
      ? { additionalContainerEnv: spec.additionalContainerEnv }
      : {}),
    ...(spec.runAsUser !== undefined ? { runAsUser: spec.runAsUser } : {}),
  });

  const outcome = await runTrackedSpawn({
    command: "docker",
    args: dockerArgs,
    config: {
      idleTimeoutMs: spec.idleTimeoutMs,
      maxWallClockMs: spec.maxWallClockMs,
      completionGraceMs: spec.completionGraceMs,
    },
    spawnFn: spawnTracked,
    clock: defaultTrackedSpawnClock,
    options: {
      ...(spec.outputFormat !== undefined ? { outputFormat: spec.outputFormat } : {}),
      ...(onOutputChunk !== undefined ? { onOutputChunk } : {}),
    },
  });

  return {
    stdout: outcome.stdout,
    stderr: outcome.stderr,
    exitCode: outcome.exitCode,
    signal: outcome.signal,
    elapsedMs: outcome.elapsedMs,
    killReason: outcome.killReason,
  };
}

export interface RecordedContainerRun {
  readonly spec: ContainerRunSpec;
  readonly options: ContainerRuntimeRunOptions | undefined;
}

/** Test double — captures specs without invoking OCI. */
export class RecordingContainerRuntime implements ContainerRuntime {
  readonly id = "docker" as const;
  readonly runs: RecordedContainerRun[] = [];
  readonly result: ContainerRunResult;

  constructor(result: ContainerRunResult) {
    this.result = result;
  }

  run(spec: ContainerRunSpec, options?: ContainerRuntimeRunOptions): Promise<ContainerRunResult> {
    this.runs.push({ spec, options });
    return Promise.resolve(this.result);
  }
}
