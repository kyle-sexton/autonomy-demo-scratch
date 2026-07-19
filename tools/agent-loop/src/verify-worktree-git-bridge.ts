#!/usr/bin/env node
/**
 * Tier-0 gate: git status inside thin container with linked-worktree bridge mounts.
 */
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { CURSOR_AGENT_POOL } from "./agent-pool.js";
import { CONTAINER_PROBE_MAX_WALL_CLOCK_MS, CONTAINER_WORKSPACE_MOUNT } from "./constants.js";
import { createDockerContainerRuntime } from "./container-runtime.js";
import { resolveSessionContainerSetup } from "./session-container-setup.js";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function usage(): void {
  process.stderr.write(
    [
      "Usage: node build/verify-worktree-git-bridge.js [workspace-root]",
      "",
      "Tier-0: git status in agent-loop-cursor:thin with worktree git bridge.",
      "Requires: docker, agent-loop-cursor:thin image.",
      "",
    ].join("\n"),
  );
}

function resolveWorkspaceRoot(argv: readonly string[]): string {
  const arg = argv[2];
  if (arg === "--help" || arg === "-h") {
    usage();
    process.exit(0);
  }
  if (arg !== undefined && arg.trim() !== "") {
    return resolve(arg.trim());
  }
  return resolve(PROJECT_ROOT, "../..");
}

async function main(): Promise<void> {
  const workspaceRoot = resolveWorkspaceRoot(process.argv);
  const tier0RunId = `tier0-git-${String(Date.now())}`;
  const setup = resolveSessionContainerSetup({
    pool: CURSOR_AGENT_POOL,
    hostWorkspacePath: workspaceRoot,
    agentLoopProjectRoot: PROJECT_ROOT,
    runId: tier0RunId,
    credentialMounts: [],
  });

  if (setup.gitBridge.mode === "unavailable") {
    process.stderr.write(
      "error: git bridge unavailable for workspace (plain clone or missing .git is OK — skip on non-worktree layouts)\n",
    );
    process.exit(1);
  }

  const runtime = createDockerContainerRuntime();
  const outcome = await runtime.run({
    image: CURSOR_AGENT_POOL.containerImage,
    name: `agent-loop-tier0-git-${Date.now()}`,
    labels: { "agent-loop.component": "tier0-git-bridge" },
    workspaceHostPath: workspaceRoot,
    workspaceContainerPath: CONTAINER_WORKSPACE_MOUNT,
    envVarNames: [],
    additionalBindMounts: setup.additionalBindMounts,
    additionalContainerEnv: setup.additionalContainerEnv,
    command: [
      "bash",
      "-lc",
      // rev-parse is the Tier-0 probe — full `git status` on Windows bind mounts can exceed probe wall clock.
      `git -C "${CONTAINER_WORKSPACE_MOUNT}" rev-parse --is-inside-work-tree >/dev/null; echo GIT_STATUS_EXIT=$?`,
    ],
    idleTimeoutMs: CONTAINER_PROBE_MAX_WALL_CLOCK_MS,
    maxWallClockMs: CONTAINER_PROBE_MAX_WALL_CLOCK_MS,
    completionGraceMs: 0,
  });

  const combined = `${outcome.stdout}\n${outcome.stderr}`;
  if (outcome.exitCode !== 0) {
    process.stderr.write(
      `error: container exit ${String(outcome.exitCode)}\n${combined.slice(0, 4000)}`,
    );
    process.exit(1);
  }

  const statusLine = combined.split("\n").find((line) => line.startsWith("GIT_STATUS_EXIT="));
  const statusExit = statusLine?.slice("GIT_STATUS_EXIT=".length).trim();
  if (statusExit !== "0") {
    process.stderr.write(
      `error: git status exit ${statusExit ?? "unknown"}\n${combined.slice(0, 4000)}`,
    );
    process.exit(1);
  }

  process.stdout.write(
    `verify-worktree-git-bridge: PASS (layout=${setup.gitBridge.layout}, mode=${setup.gitBridge.mode})\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
});
