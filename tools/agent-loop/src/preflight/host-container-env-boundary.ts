import { LOG_PREFIX } from "../constants.js";
import {
  containerWorkspaceSentinels,
  isContainerWorkspaceSentinel,
} from "../container-boundary.js";
import type { RunLoopPorts } from "../ports.js";

const HOST_CONTAINER_ENV_EXIT_CODE = 5;

/**
 * Refuse to launch when the host process has container workspace paths in env.
 * Container paths belong inside Docker only (orchestrator `additionalContainerEnv`).
 */
export function assertHostContainerEnvBoundary(params: {
  readonly env: NodeJS.ProcessEnv;
  readonly ports: RunLoopPorts;
}): void {
  for (const name of ["CLAUDE_PROJECT_DIR", "GIT_WORK_TREE"] as const) {
    const value = params.env[name];
    if (!isContainerWorkspaceSentinel(value, params.env)) {
      continue;
    }
    params.ports.console.error(
      `${LOG_PREFIX} ${name} is set to the container-only path ${JSON.stringify(value?.trim())} on the host.`,
    );
    params.ports.console.error(
      `${LOG_PREFIX} Unset it from your OS user environment and shell profile.`,
    );
    params.ports.console.error(
      `${LOG_PREFIX} See tools/agent-loop/README.md "Container vs host environment".`,
    );
    params.ports.exit.exit(HOST_CONTAINER_ENV_EXIT_CODE);
  }
}

/** Exported for tests and shell parity script documentation. */
export function hostContainerEnvSentinels(env: NodeJS.ProcessEnv): readonly string[] {
  return containerWorkspaceSentinels(env);
}
