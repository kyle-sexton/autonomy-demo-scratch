import type { AgentPool } from "./agent-pool.js";
import { type CapabilityProfile, loadCapabilityProfile } from "./capabilities/load-profile.js";
import { CODEX_HOME_CONTAINER } from "./codex-auth.js";
import { CONTAINER_WORKSPACE_MOUNT } from "./constants.js";
import { buildContainerGitConfigEnv } from "./container-git-config.js";
import { GROK_HOME_CONTAINER } from "./grok-auth.js";
import { resolvePoolSessionBindMounts } from "./pool-session-bind-mounts/resolve.js";
import type { WorkspaceBindMount } from "./types.js";
import { resolveWorkspaceGitBridge } from "./workspace-git-bridge/resolve.js";
import type { WorkspaceGitBridge } from "./workspace-git-bridge/types.js";

export interface SessionContainerSetup {
  readonly capabilityProfile: CapabilityProfile;
  readonly gitBridge: WorkspaceGitBridge;
  readonly additionalBindMounts: readonly WorkspaceBindMount[];
  readonly additionalContainerEnv: Readonly<Record<string, string>>;
}

export interface ResolveSessionContainerSetupInput {
  readonly pool: AgentPool;
  readonly hostWorkspacePath: string;
  readonly agentLoopProjectRoot: string;
  readonly runId: string;
  readonly credentialMounts: readonly WorkspaceBindMount[];
}

/** Compose git bridge, pool session mounts, and capability profile for one run. */
export function resolveSessionContainerSetup(
  input: ResolveSessionContainerSetupInput,
): SessionContainerSetup {
  const capabilityProfile = loadCapabilityProfile(
    input.pool.capabilityProfileId,
    input.agentLoopProjectRoot,
  );
  const gitBridge = resolveWorkspaceGitBridge({
    hostWorkspacePath: input.hostWorkspacePath,
    containerWorkspacePath: CONTAINER_WORKSPACE_MOUNT,
    gitBridgePolicy: capabilityProfile.gitBridge,
  });
  const sessionBindMounts = resolvePoolSessionBindMounts(input.pool, {
    workspaceRoot: input.hostWorkspacePath,
    agentLoopProjectRoot: input.agentLoopProjectRoot,
    runId: input.runId,
  });
  const additionalBindMounts = [
    ...input.credentialMounts,
    ...gitBridge.bindMounts,
    ...sessionBindMounts,
  ];
  const additionalContainerEnv: Record<string, string> = {
    ...buildContainerGitConfigEnv(),
    ...gitBridge.containerEnv,
    CLAUDE_PROJECT_DIR: CONTAINER_WORKSPACE_MOUNT,
    ...(input.pool.cli === "codex"
      ? { HOME: CONTAINER_WORKSPACE_MOUNT, CODEX_HOME: CODEX_HOME_CONTAINER }
      : input.pool.cli === "grok"
        ? { HOME: CONTAINER_WORKSPACE_MOUNT, GROK_HOME: GROK_HOME_CONTAINER }
        : {}),
  };
  if (gitBridge.layout !== "none") {
    additionalContainerEnv["AGENT_LOOP_GIT_BRIDGE_LAYOUT"] = gitBridge.layout;
    additionalContainerEnv["AGENT_LOOP_GIT_BRIDGE_MODE"] = gitBridge.mode;
  }

  return {
    capabilityProfile,
    gitBridge,
    additionalBindMounts,
    additionalContainerEnv,
  };
}
