import type { WorkspaceBindMount } from "../types.js";

export type WorkspaceGitLayout = "plain" | "linked" | "none";

export type GitBridgeMode = "unavailable" | "read" | "read-write";

export type GitBridgePolicy = "auto" | GitBridgeMode;

/** Fixed in-container mount for the bare hub object store. */
export const CONTAINER_BARE_GIT_MOUNT = "/.agent-loop-git/bare";

export interface WorkspaceGitBridge {
  readonly layout: WorkspaceGitLayout;
  readonly mode: GitBridgeMode;
  readonly bindMounts: readonly WorkspaceBindMount[];
  readonly containerEnv: Readonly<Record<string, string>>;
}

export interface ResolveWorkspaceGitBridgeInput {
  readonly hostWorkspacePath: string;
  readonly containerWorkspacePath: string;
  readonly gitBridgePolicy?: GitBridgePolicy;
}
