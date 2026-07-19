#!/usr/bin/env node
/**
 * Operator readiness rollup for agent-loop pools — no Docker spend unless --tier0.
 * Usage: node build/preflight-pool.js --pool <pool-id> [--tier0] [workspace-root]
 *        node build/preflight-pool.js --all [--tier0] [workspace-root]
 */
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { loadProjectEnv } from "./env.js";
import {
  printCheckResults,
  resolveProfilesForRun,
  runPoolReadinessChecks,
  summarizeResults,
} from "./preflight/pool-readiness.js";
import { PREFLIGHT_POOL_IDS } from "./preflight/pool-readiness-config.js";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REPO_ROOT = resolve(PROJECT_ROOT, "../..");

function usage(): void {
  process.stdout.write(
    [
      "Usage: node build/preflight-pool.js --pool <pool-id> [--tier0] [workspace-root]",
      "       node build/preflight-pool.js --all [--tier0] [workspace-root]",
      "",
      "Rollup operator readiness. Default: no subscription spend.",
      "  --tier0  Run credentialed tier-0 write gate (requires auth + attestation).",
      "",
      `Pools: ${PREFLIGHT_POOL_IDS.join(", ")}`,
      "",
    ].join("\n"),
  );
}

function parseArgs(argv: readonly string[]): {
  poolId: string | undefined;
  all: boolean;
  tier0: boolean;
  workspaceRoot: string;
} {
  let poolId: string | undefined;
  let all = false;
  let tier0 = false;
  const positional: string[] = [];

  for (let index = 2; index < argv.length; index++) {
    const arg = argv[index] ?? "";
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--tier0") {
      tier0 = true;
      continue;
    }
    if (arg === "--all") {
      all = true;
      continue;
    }
    if (arg === "--pool") {
      poolId = argv[++index]?.trim();
      continue;
    }
    if (arg.startsWith("--pool=")) {
      poolId = arg.slice("--pool=".length).trim();
      continue;
    }
    positional.push(arg);
  }

  const workspaceArg = positional[0];
  const workspaceRoot =
    workspaceArg !== undefined && workspaceArg.trim() !== ""
      ? resolve(workspaceArg.trim())
      : REPO_ROOT;

  return { poolId, all, tier0, workspaceRoot };
}

function main(): void {
  const { poolId, all, tier0, workspaceRoot } = parseArgs(process.argv);
  loadProjectEnv(PROJECT_ROOT);

  if (!all && poolId === undefined) {
    usage();
    process.exit(2);
  }

  const profiles = resolveProfilesForRun(poolId, all);
  if (profiles.length === 0) {
    process.stderr.write(`error: unknown pool "${poolId ?? ""}"\n`);
    process.exit(2);
  }

  let totalFail = 0;
  let totalWarn = 0;

  for (const [index, profile] of profiles.entries()) {
    const results = runPoolReadinessChecks({
      profile,
      projectRoot: PROJECT_ROOT,
      repoRoot: REPO_ROOT,
      env: process.env,
      credentialed: tier0,
      workspaceRoot,
      includeShared: all ? index === 0 : true,
    });
    printCheckResults(profile.pool.id, results);
    const summary = summarizeResults(results);
    totalFail += summary.failCount;
    totalWarn += summary.warnCount;
  }

  process.stdout.write(`\npreflight-pool: ${totalFail} fail, ${totalWarn} warn\n`);
  process.exit(totalFail > 0 ? 1 : 0);
}

main();
