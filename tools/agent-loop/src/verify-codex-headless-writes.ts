#!/usr/bin/env node
/**
 * Tier-0 gate: one headless `codex exec` write in the thin pool image.
 * Spend-gated — requires attestation (or --skip-spend-gate for local dev only).
 */
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

import { CODEX_AGENT_POOL, resolvePoolAdditionalBindMounts } from "./agent-pool.js";
import { CONTAINER_WORKSPACE_MOUNT } from "./constants.js";
import { loadProjectEnv } from "./env.js";
import { loadPoolsConfigForSpendGate } from "./spend-gate.js";
import {
  agentLoopProjectRoot,
  DEFAULT_MAX_WALL_CLOCK_MS,
  resolveTier0WorkspaceRoot,
  runHeadlessTier0Probe,
} from "./tier0-probe.js";

const PROJECT_ROOT = agentLoopProjectRoot(import.meta.url);
const TIER0_PROBE_RELATIVE =
  process.env["AGENT_LOOP_TIER0_PROBE_RELATIVE"] ?? "out/headless-codex-tier0.probe";

function usage(): void {
  process.stderr.write(
    [
      "Usage: node build/verify-codex-headless-writes.js [workspace-root] [--skip-spend-gate]",
      "",
      "Tier-0: codex exec headless write with auth bind-mount.",
      "Requires: spend-safety attestation (or --skip-spend-gate), ~/.codex/auth.json, docker, agent-loop-codex:thin image.",
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
    CODEX_AGENT_POOL,
    PROJECT_ROOT,
    poolsConfig,
  );

  await runHeadlessTier0Probe({
    pool: CODEX_AGENT_POOL,
    projectRoot: PROJECT_ROOT,
    workspaceRoot,
    skipSpendGate,
    probeRelative: TIER0_PROBE_RELATIVE,
    passLabel: "verify-codex-headless-writes: PASS",
    tier0RunIdPrefix: "tier0-codex",
    containerNamePrefix: "agent-loop-tier0-codex",
    componentLabel: "tier0-codex-headless-write",
    maxWallClockMs: DEFAULT_MAX_WALL_CLOCK_MS,
    agentExitLabel: "codex",
    credentialMounts,
    preRunAuthCheck: () => {
      const authPath = resolve(homedir(), ".codex", "auth.json");
      if (!existsSync(authPath)) {
        process.stderr.write(`error: missing Codex auth at ${authPath}\n`);
        process.exit(1);
      }
    },
    buildRunSpec: ({ prompt, workspaceRoot: wsRoot, containerSetup }) => ({
      image: CODEX_AGENT_POOL.containerImage,
      name: `agent-loop-tier0-codex-${Date.now()}`,
      labels: { "agent-loop.component": "tier0-codex-headless-write" },
      workspaceHostPath: wsRoot,
      workspaceContainerPath: CONTAINER_WORKSPACE_MOUNT,
      envVarNames: [],
      additionalBindMounts: containerSetup.additionalBindMounts,
      ...(Object.keys(containerSetup.additionalContainerEnv).length > 0
        ? { additionalContainerEnv: containerSetup.additionalContainerEnv }
        : {}),
      command: ["codex", "exec", "--json", "--full-auto", "--sandbox", "workspace-write", prompt],
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
