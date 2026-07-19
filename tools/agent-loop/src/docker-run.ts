import { randomBytes } from "node:crypto";
import { basename } from "node:path";

import { CONTAINER_NAME_MAX_LEN, CONTAINER_NAME_PREFIX, DOCKER_LABEL_PREFIX } from "./constants.js";
import { resolveDockerBindMountHostPath } from "./docker-host-path.js";
import { RUN_LOGS_SUBDIRECTORY } from "./iteration-artifacts.js";
import type { AgentCliKind, WorkspaceBindMount } from "./types.js";

export { DOCKER_LABEL_PREFIX };

export interface DockerRunIdentity {
  readonly runId: string;
  readonly workspaceSlug: string;
  readonly containerName: string;
  readonly labels: Readonly<Record<string, string>>;
}

/** Compact UTC stamp aligned with work-artifact journal and verification timestamps. */
export function formatCompactUtcRunTimestamp(now: Date = new Date()): string {
  return now.toISOString().replace(/[-:]/g, "").replace(".", "");
}

function sanitizeRunLabel(raw: string): string {
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug.length > 0 ? slug.slice(0, 48) : "run";
}

/**
 * Run directory name: compactUtcTimestamp + label (date-prefix for chronological sort).
 * Label = AGENT_LOOP_RUN_ID or RALPH_RUN_ID when set, else workspace slug.
 */
export function createRunId(
  now: Date = new Date(),
  runLabelOverride?: string,
  workspaceSlug?: string,
): string {
  const stamp = formatCompactUtcRunTimestamp(now);
  const label = sanitizeRunLabel(
    runLabelOverride !== undefined && runLabelOverride.trim() !== ""
      ? runLabelOverride.trim()
      : (workspaceSlug ?? "run"),
  );
  const uniqueSuffix = randomBytes(3).toString("hex");
  return `${stamp}-${label}-${uniqueSuffix}`;
}

/** Slugify a workspace directory name for Docker container names and labels. */
export function workspaceSlugFromPath(workspacePath: string): string {
  const raw = basename(workspacePath);
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug.length > 0 ? slug.slice(0, 48) : "workspace";
}

/**
 * Human- and Docker-Desktop-friendly container name.
 * Pattern: agent-loop-{tool}-{workspaceSlug}-{runTail}-i{iteration}
 */
export function buildContainerName(params: {
  cli: AgentCliKind;
  workspaceSlug: string;
  runId: string;
  iteration: number;
}): string {
  const runTail = params.runId.replace(/[^a-zA-Z0-9]/g, "").slice(-12);
  const name = `${CONTAINER_NAME_PREFIX}-${params.cli}-${params.workspaceSlug}-${runTail}-i${params.iteration}`;
  return name.slice(0, CONTAINER_NAME_MAX_LEN);
}

export function buildDockerRunIdentity(params: {
  cli: AgentCliKind;
  workspacePath: string;
  runId: string;
  iteration: number;
  iterLabel: string;
}): DockerRunIdentity {
  const workspaceSlug = workspaceSlugFromPath(params.workspacePath);
  const containerName = buildContainerName({
    cli: params.cli,
    workspaceSlug,
    runId: params.runId,
    iteration: params.iteration,
  });
  const labels: Record<string, string> = {
    [`${DOCKER_LABEL_PREFIX}cli`]: params.cli,
    [`${DOCKER_LABEL_PREFIX}run-id`]: params.runId,
    [`${DOCKER_LABEL_PREFIX}workspace-slug`]: workspaceSlug,
    [`${DOCKER_LABEL_PREFIX}iteration`]: String(params.iteration),
    [`${DOCKER_LABEL_PREFIX}iter-label`]: params.iterLabel,
  };
  return { runId: params.runId, workspaceSlug, containerName, labels };
}

/** Flatten labels into docker CLI `--label key=value` pairs. */
export function dockerLabelArgs(labels: Readonly<Record<string, string>>): string[] {
  return Object.entries(labels).flatMap(([key, value]) => ["--label", `${key}=${value}`]);
}

export interface DockerRunSpec {
  readonly image: string;
  readonly containerName: string;
  readonly workspaceHostPath: string;
  readonly workspaceContainerPath: string;
  readonly requiredEnv: readonly string[];
  readonly command: readonly string[];
  readonly labels: Readonly<Record<string, string>>;
  readonly additionalBindMounts?: readonly WorkspaceBindMount[];
  /** Orchestrator-computed `-e KEY=value` pairs (not read from host env). */
  readonly additionalContainerEnv?: Readonly<Record<string, string>>;
  /** When set, passed to `docker run --user` for bind-mount file ownership (Linux). */
  readonly runAsUser?: string;
}

function bindMountArg(mount: WorkspaceBindMount): string {
  const hostPath = resolveDockerBindMountHostPath(mount.hostPath);
  const suffix = mount.readOnly === true ? ":ro" : "";
  return `${hostPath}:${mount.containerPath}${suffix}`;
}

/** Build the `docker run` argv prefix through the image name (command follows). */
export function buildDockerRunArgs(spec: DockerRunSpec): string[] {
  const workspaceHostPath = resolveDockerBindMountHostPath(spec.workspaceHostPath);
  const volumeArgs = [
    "-v",
    `${workspaceHostPath}:${spec.workspaceContainerPath}`,
    ...(spec.additionalBindMounts ?? []).flatMap((mount) => ["-v", bindMountArg(mount)]),
  ];

  return [
    "run",
    "--rm",
    "--name",
    spec.containerName,
    ...dockerLabelArgs(spec.labels),
    ...(spec.runAsUser !== undefined ? ["--user", spec.runAsUser] : []),
    "-w",
    spec.workspaceContainerPath,
    ...volumeArgs,
    ...spec.requiredEnv.flatMap((name) => ["-e", name]),
    ...Object.entries(spec.additionalContainerEnv ?? {}).flatMap(([key, value]) => [
      "-e",
      `${key}=${value}`,
    ]),
    spec.image,
    ...spec.command,
  ];
}

/**
 * Per-run log directory under the tool (or `RALPH_LOG_DIR` override).
 * Isolates concurrent runs: `logs/runs/<runId>/orchestrator.log`, iteration agent-output logs.
 */
export function resolveRunLogsDirectory(
  projectRoot: string,
  runId: string,
  envLogDir?: string,
): string {
  const base =
    envLogDir !== undefined && envLogDir.trim() !== "" ? envLogDir.trim() : `${projectRoot}/logs`;
  return `${base}/${RUN_LOGS_SUBDIRECTORY}/${runId}`;
}
