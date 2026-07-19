#!/usr/bin/env node
/**
 * Tier-0 gate: one headless `grok -p` write in the thin pool image.
 * Spend-gated — requires attestation (or --skip-spend-gate for local dev only).
 */
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

import {
  GROK_AGENT_POOL,
  resolvePoolAdapter,
  resolvePoolAdditionalBindMounts,
} from "./agent-pool.js";
import { CONTAINER_WORKSPACE_MOUNT } from "./constants.js";
import { loadProjectEnv } from "./env.js";
import { loadPoolsConfigForSpendGate } from "./spend-gate.js";
import {
  agentLoopProjectRoot,
  resolveTier0WorkspaceRoot,
  runHeadlessTier0Probe,
} from "./tier0-probe.js";

const PROJECT_ROOT = agentLoopProjectRoot(import.meta.url);
const TIER0_PROBE_RELATIVE =
  process.env["AGENT_LOOP_TIER0_PROBE_RELATIVE"] ?? "out/headless-grok-tier0.probe";
const GROK_MAX_WALL_CLOCK_MS = 300_000;

function usage(): void {
  process.stderr.write(
    [
      "Usage: node build/verify-grok-headless-writes.js [workspace-root] [--skip-spend-gate]",
      "",
      "Tier-0: grok -p headless write with auth bind-mount.",
      "Requires: spend-safety attestation (or --skip-spend-gate), ~/.grok/auth.json, docker, agent-loop-grok:thin image.",
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
  );
  const poolsConfig = loadPoolsConfigForSpendGate(PROJECT_ROOT);
  const credentialMounts = resolvePoolAdditionalBindMounts(
    GROK_AGENT_POOL,
    PROJECT_ROOT,
    poolsConfig,
  );

  await runHeadlessTier0Probe({
    pool: GROK_AGENT_POOL,
    projectRoot: PROJECT_ROOT,
    workspaceRoot,
    skipSpendGate,
    probeRelative: TIER0_PROBE_RELATIVE,
    passLabel: "verify-grok-headless-writes: PASS",
    tier0RunIdPrefix: "tier0-grok",
    containerNamePrefix: "agent-loop-tier0-grok",
    componentLabel: "tier0-grok-headless-write",
    maxWallClockMs: GROK_MAX_WALL_CLOCK_MS,
    agentExitLabel: "grok",
    credentialMounts,
    preRunAuthCheck: () => {
      const authPath = resolve(homedir(), ".grok", "auth.json");
      if (!existsSync(authPath)) {
        process.stderr.write(`error: missing Grok auth at ${authPath}\n`);
        process.exit(1);
      }
    },
    buildRunSpec: ({ prompt, workspaceRoot: wsRoot, containerSetup }) => {
      const inv = resolvePoolAdapter(GROK_AGENT_POOL)({
        containerImage: GROK_AGENT_POOL.containerImage,
        hostWorkspacePath: wsRoot,
        containerWorkspacePath: CONTAINER_WORKSPACE_MOUNT,
        prompt,
        iterationLabel: "tier0-grok",
        outputFormat: "stream-json",
      });
      return {
        image: GROK_AGENT_POOL.containerImage,
        name: `agent-loop-tier0-grok-${Date.now()}`,
        labels: { "agent-loop.component": "tier0-grok-headless-write" },
        workspaceHostPath: wsRoot,
        workspaceContainerPath: CONTAINER_WORKSPACE_MOUNT,
        envVarNames: [],
        additionalBindMounts: containerSetup.additionalBindMounts,
        ...(Object.keys(containerSetup.additionalContainerEnv).length > 0
          ? { additionalContainerEnv: containerSetup.additionalContainerEnv }
          : {}),
        command: inv.command,
        idleTimeoutMs: GROK_MAX_WALL_CLOCK_MS,
        maxWallClockMs: GROK_MAX_WALL_CLOCK_MS,
        completionGraceMs: 0,
        outputFormat: "stream-json",
      };
    },
  });
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
});
