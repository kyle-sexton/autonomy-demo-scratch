import { join } from "node:path";

import type { AgentCliKind } from "./types.js";

/** Orchestrator decision log for one run (banner, iteration summaries, exit). */
export const ORCHESTRATOR_LOG_FILENAME = "orchestrator.log";

/** Subdirectory under `logs/` (or `RALPH_LOG_DIR`) that holds per-run folders. */
export const RUN_LOGS_SUBDIRECTORY = "runs";

/** Stable prefix for iteration-scoped log and meta filenames. */
export function formatIterationLabel(iteration: number, agentCli: AgentCliKind): string {
  return `iteration-${String(iteration).padStart(2, "0")}-${agentCli}`;
}

export function iterationAgentOutputLogPath(logsDirectory: string, iterationLabel: string): string {
  return join(logsDirectory, `${iterationLabel}-agent-output.log`);
}

export function iterationMetaPath(logsDirectory: string, iterationLabel: string): string {
  return join(logsDirectory, `${iterationLabel}-meta.json`);
}

export function iterationToolCallsPath(logsDirectory: string, iterationLabel: string): string {
  return join(logsDirectory, `${iterationLabel}-tool-calls.jsonl`);
}

export function iterationHookReportPath(logsDirectory: string, iterationLabel: string): string {
  return join(logsDirectory, `${iterationLabel}-hook-report.json`);
}

export const CONTAINER_PROBE_FILENAME = "container-probe.json";

/** Path inside the agent-loop tool bind mount to the container probe script. */
export const CONTAINER_PROBE_SCRIPT_CONTAINER_PATH = "scripts/probe-container-env.sh";

export function containerProbePath(logsDirectory: string): string {
  return join(logsDirectory, CONTAINER_PROBE_FILENAME);
}
