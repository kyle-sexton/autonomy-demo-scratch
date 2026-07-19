#!/usr/bin/env node
/**
 * Tier-0 gate: one headless cursor-agent Write with session suppression mounts.
 * Spend-gated — requires attestation (or --skip-spend-gate for local dev only).
 */
import { CURSOR_AGENT_POOL } from "./agent-pool.js";
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
  process.env["AGENT_LOOP_TIER0_PROBE_RELATIVE"] ?? "out/headless-hook-tier0.probe";

function usage(): void {
  process.stderr.write(
    [
      "Usage: node build/verify-headless-writes.js [workspace-root] [--skip-spend-gate]",
      "",
      "Tier-0: cursor-agent headless Write with pool session suppression mounts.",
      "Requires: spend-safety attestation (or --skip-spend-gate), CURSOR_API_KEY, docker, agent-loop-cursor:thin image.",
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

  if (process.env["CURSOR_API_KEY"] === undefined || process.env["CURSOR_API_KEY"].trim() === "") {
    process.stderr.write("error: CURSOR_API_KEY is required\n");
    process.exit(1);
  }

  await runHeadlessTier0Probe({
    pool: CURSOR_AGENT_POOL,
    projectRoot: PROJECT_ROOT,
    workspaceRoot,
    skipSpendGate,
    probeRelative: TIER0_PROBE_RELATIVE,
    passLabel: "verify-headless-writes: PASS",
    tier0RunIdPrefix: "tier0",
    containerNamePrefix: "agent-loop-tier0",
    componentLabel: "tier0-headless-write",
    maxWallClockMs: DEFAULT_MAX_WALL_CLOCK_MS,
    agentExitLabel: "cursor-agent",
    hookBlockedExtra: (combinedOutput) =>
      combinedOutput.includes("conversation_id") || combinedOutput.includes("windows_temp_file"),
    buildRunSpec: ({ prompt, workspaceRoot: wsRoot, containerSetup }) => ({
      image: CURSOR_AGENT_POOL.containerImage,
      name: `agent-loop-tier0-${Date.now()}`,
      labels: { "agent-loop.component": "tier0-headless-write" },
      workspaceHostPath: wsRoot,
      workspaceContainerPath: CONTAINER_WORKSPACE_MOUNT,
      envVarNames: ["CURSOR_API_KEY"],
      additionalBindMounts: containerSetup.additionalBindMounts,
      ...(Object.keys(containerSetup.additionalContainerEnv).length > 0
        ? { additionalContainerEnv: containerSetup.additionalContainerEnv }
        : {}),
      command: [
        "cursor-agent",
        "--print",
        "--force",
        "--trust",
        "--output-format",
        "text",
        "--workspace",
        CONTAINER_WORKSPACE_MOUNT,
        prompt,
      ],
      idleTimeoutMs: DEFAULT_MAX_WALL_CLOCK_MS,
      maxWallClockMs: DEFAULT_MAX_WALL_CLOCK_MS,
      completionGraceMs: 0,
    }),
  });
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
});
