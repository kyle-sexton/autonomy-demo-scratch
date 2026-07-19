#!/usr/bin/env node
/**
 * Tier-0 gate: one headless `claude -p` write with native in-container hooks.
 * Spend-gated — requires attestation (or --skip-spend-gate for local dev only).
 */
import { CLAUDE_AGENT_POOL, resolvePoolAdapter } from "./agent-pool.js";
import {
  resolveClaudeContainerRunUser,
  validateClaudeSubscriptionAuth,
} from "./claude-headless-config.js";
import { CONTAINER_WORKSPACE_MOUNT } from "./constants.js";
import { loadProjectEnv } from "./env.js";
import {
  agentLoopProjectRoot,
  DEFAULT_MAX_WALL_CLOCK_MS,
  resolveTier0WorkspaceRoot,
  runHeadlessTier0Probe,
} from "./tier0-probe.js";

const PROJECT_ROOT = agentLoopProjectRoot(import.meta.url);
const TIER0_PROBE_RELATIVE =
  process.env["AGENT_LOOP_TIER0_PROBE_RELATIVE"] ?? "out/headless-claude-tier0.probe";

function usage(): void {
  process.stderr.write(
    [
      "Usage: node build/verify-claude-headless-writes.js [workspace-root] [--skip-spend-gate]",
      "",
      "Tier-0: claude -p headless write with native hooks (inContainerHooks=native).",
      "Requires: spend-safety attestation (or --skip-spend-gate), CLAUDE_CODE_OAUTH_TOKEN, docker, agent-loop-claude:thin image.",
      "",
    ].join("\n"),
  );
}

async function main(): Promise<void> {
  loadProjectEnv(PROJECT_ROOT);
  const { workspaceRoot, skipSpendGate } = resolveTier0WorkspaceRoot(
    process.argv,
    PROJECT_ROOT,
    usage,
    { normalizePath: true },
  );

  await runHeadlessTier0Probe({
    pool: CLAUDE_AGENT_POOL,
    projectRoot: PROJECT_ROOT,
    workspaceRoot,
    skipSpendGate,
    probeRelative: TIER0_PROBE_RELATIVE,
    passLabel: "verify-claude-headless-writes: PASS",
    tier0RunIdPrefix: "tier0-claude",
    containerNamePrefix: "agent-loop-tier0-claude",
    componentLabel: "tier0-claude-headless-write",
    maxWallClockMs: DEFAULT_MAX_WALL_CLOCK_MS,
    agentExitLabel: "claude",
    hookBlockedMessage:
      "error: hook block detected in tier-0 output (inspect native hooks / image deps)\n",
    preRunAuthCheck: () => {
      const message = validateClaudeSubscriptionAuth(process.env);
      if (message !== undefined) {
        process.stderr.write(`error: ${message}\n`);
        process.exit(1);
      }
    },
    buildRunSpec: ({ prompt, workspaceRoot: wsRoot, containerSetup }) => {
      const inv = resolvePoolAdapter(CLAUDE_AGENT_POOL)({
        containerImage: CLAUDE_AGENT_POOL.containerImage,
        hostWorkspacePath: wsRoot,
        containerWorkspacePath: CONTAINER_WORKSPACE_MOUNT,
        prompt,
        iterationLabel: "tier0-claude",
        outputFormat: "stream-json",
      });
      return {
        image: CLAUDE_AGENT_POOL.containerImage,
        name: `agent-loop-tier0-claude-${Date.now()}`,
        labels: { "agent-loop.component": "tier0-claude-headless-write" },
        workspaceHostPath: wsRoot,
        workspaceContainerPath: CONTAINER_WORKSPACE_MOUNT,
        envVarNames: inv.requiredEnv,
        additionalBindMounts: containerSetup.additionalBindMounts,
        ...(Object.keys(containerSetup.additionalContainerEnv).length > 0
          ? { additionalContainerEnv: containerSetup.additionalContainerEnv }
          : {}),
        command: inv.command,
        idleTimeoutMs: DEFAULT_MAX_WALL_CLOCK_MS,
        maxWallClockMs: DEFAULT_MAX_WALL_CLOCK_MS,
        completionGraceMs: 0,
        outputFormat: "stream-json",
        runAsUser: resolveClaudeContainerRunUser(wsRoot),
      };
    },
  });
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
});
