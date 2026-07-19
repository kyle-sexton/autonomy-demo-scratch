import { HOST_GIT_CONFIG_LEAK_EXIT_CODE, LOG_PREFIX } from "../constants.js";
import {
  auditHostGitConfig,
  type HostGitConfigRepair,
  hostGitConfigIsClean,
  hostRequiresCoreFilemodeFalse,
  logRepairedHostCoreFilemodeLeak,
  logRepairedHostCoreWorktreeLeak,
  readHostCoreFilemode,
  readHostCoreWorktree,
  repairHostGitConfigLeaks,
} from "../container-boundary.js";
import type { RunLoopPorts } from "../ports.js";

export type { HostGitConfigRepair };

/**
 * Clear container git leaks in shared host config (bare-hub `.bare/config` or plain `.git/config`).
 * Idempotent when already clean. Returns repairs applied.
 */
export function repairHostGitConfigBoundary(params: {
  readonly hostWorkspacePath: string;
  readonly env: NodeJS.ProcessEnv;
  readonly logLine: (text: string) => void;
}): readonly HostGitConfigRepair[] {
  const worktreeBefore = readHostCoreWorktree(params.hostWorkspacePath);
  const filemodeBefore = readHostCoreFilemode(params.hostWorkspacePath);
  const repairs = repairHostGitConfigLeaks(params.hostWorkspacePath, params.env);

  for (const repair of repairs) {
    if (repair.key === "core.worktree") {
      logRepairedHostCoreWorktreeLeak(
        params.hostWorkspacePath,
        worktreeBefore ?? "",
        params.logLine,
      );
    } else if (repair.key === "core.filemode") {
      logRepairedHostCoreFilemodeLeak(params.hostWorkspacePath, filemodeBefore, params.logLine);
    } else {
      params.logLine(
        `${LOG_PREFIX} repaired host git config: ${repair.key} — ${repair.action} (repo ${params.hostWorkspacePath})`,
      );
    }
  }

  return repairs;
}

/** Fail fast when container paths persist in host git config after repair. */
export function assertHostGitConfigBoundary(params: {
  readonly hostWorkspacePath: string;
  readonly env: NodeJS.ProcessEnv;
  readonly ports: RunLoopPorts;
}): void {
  if (hostGitConfigIsClean(params.hostWorkspacePath, params.env)) {
    return;
  }

  const violations = auditHostGitConfig(params.hostWorkspacePath, params.env);
  for (const violation of violations) {
    params.ports.console.error(
      `${LOG_PREFIX} git config ${violation.key}=${JSON.stringify(violation.value)} — ${violation.reason}`,
    );
  }

  params.ports.console.error(
    `${LOG_PREFIX} Run: bash tools/agent-loop/scripts/check-host-container-env-boundary.sh`,
  );
  params.ports.console.error(`${LOG_PREFIX} See docs/agent-loop/git-container-boundary.md`);
  if (hostRequiresCoreFilemodeFalse()) {
    params.ports.console.error(
      `${LOG_PREFIX} Windows: git config --local core.filemode false  (or bash tools/bootstrap.sh)`,
    );
  }
  params.ports.console.error(`${LOG_PREFIX} core.worktree leak: git config --unset core.worktree`);
  params.ports.exit.exit(HOST_GIT_CONFIG_LEAK_EXIT_CODE);
}
