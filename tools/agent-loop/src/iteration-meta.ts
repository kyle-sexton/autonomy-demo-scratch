import type { TimeoutKillReason } from "./iteration-timeout.js";
import type { RunSession, Sentinel } from "./types.js";

export interface IterationMeta {
  readonly elapsedMs: number;
  readonly exitCode: number | null;
  readonly signal: string | null;
  readonly killReason: TimeoutKillReason | null;
  readonly sentinel: Sentinel | null;
  readonly watchdogTriggered: boolean;
  readonly completionGraceEnd: boolean;
  readonly usage?: Record<string, unknown>;
  /** Docker identity snapshot — replaces post-mortem `docker inspect` after `--rm`. */
  readonly container?: IterationContainerSnapshot;
}

export interface IterationContainerSnapshot {
  readonly name: string;
  readonly image: string;
  readonly labels: Readonly<Record<string, string>>;
  readonly workspaceHostPath: string;
  readonly workspaceContainerPath: string;
  readonly additionalBindMounts?: readonly {
    readonly hostPath: string;
    readonly containerPath: string;
    readonly readOnly?: boolean;
  }[];
  readonly runAsUser?: string;
}

export function buildIterationContainerSnapshot(
  session: RunSession,
  iteration: {
    readonly containerName: string;
    readonly containerImage: string;
    readonly dockerLabels: Readonly<Record<string, string>>;
  },
  hostWorkspacePath: string,
  containerWorkspaceMount: string,
): IterationContainerSnapshot {
  return {
    name: iteration.containerName,
    image: iteration.containerImage,
    labels: iteration.dockerLabels,
    workspaceHostPath: hostWorkspacePath,
    workspaceContainerPath: containerWorkspaceMount,
    ...(session.additionalBindMounts !== undefined && session.additionalBindMounts.length > 0
      ? {
          additionalBindMounts: session.additionalBindMounts.map((mount) => ({
            hostPath: mount.hostPath,
            containerPath: mount.containerPath,
            ...(mount.readOnly === true ? { readOnly: true } : {}),
          })),
        }
      : {}),
    ...(session.containerRunUser !== undefined ? { runAsUser: session.containerRunUser } : {}),
  };
}

export function buildIterationMeta(params: {
  readonly elapsedMs: number;
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly killReason: TimeoutKillReason | null;
  readonly sentinel: Sentinel | null;
  readonly watchdogTriggered: boolean;
  readonly completionGraceEnd: boolean;
  readonly usage?: Record<string, unknown>;
  readonly container?: IterationContainerSnapshot;
}): IterationMeta {
  return {
    elapsedMs: params.elapsedMs,
    exitCode: params.exitCode,
    signal: params.signal,
    killReason: params.killReason,
    sentinel: params.sentinel,
    watchdogTriggered: params.watchdogTriggered,
    completionGraceEnd: params.completionGraceEnd,
    ...(params.usage !== undefined ? { usage: params.usage } : {}),
    ...(params.container !== undefined ? { container: params.container } : {}),
  };
}
