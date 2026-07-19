import { join } from "node:path";

import type { CompletionGateResult } from "./completion-gates.js";
import { AGENT_FAILED_EXIT_CODE, HOST_VERIFY_FAILED_EXIT_CODE, LOG_PREFIX } from "./constants.js";
import type { ContainerProbeResult } from "./container-probe.js";
import type { IterationHookReport } from "./hook-observability.js";
import { runHostVerifyScript } from "./host-verify.js";
import type { RunLoopPorts } from "./ports.js";
import { repairHostGitConfigBoundary } from "./preflight/host-git-config-boundary.js";
import { formatRunComplete, type TokenUsageLine } from "./run-console.js";
import type { IterationSummaryRow, RunLoopRunState } from "./run-loop-run-state.js";
import { buildRunSummaryMarkdown } from "./run-summary.js";
import type { CompletionResult, RunSession } from "./types.js";
import { captureGitSnapshot, diffSnapshots, type GitSnapshot } from "./workspace-snapshot.js";

export interface FinishRunOptions {
  readonly session: RunSession;
  readonly ports: RunLoopPorts;
  readonly logLine: (text: string) => void;
  readonly runLogPath: string;
  readonly logsDirectory: string;
  readonly iteration: number;
  readonly gateResult: CompletionGateResult;
  readonly completionDecision: CompletionResult;
  readonly gitBefore: GitSnapshot;
  readonly iterationRows: readonly IterationSummaryRow[];
  readonly hookReports: readonly IterationHookReport[];
  readonly containerProbe?: ContainerProbeResult;
  readonly finalExitCode: number;
  readonly abortReason?: string;
  readonly lastUsage?: TokenUsageLine;
  readonly runHostVerify: boolean;
}

export function resolveAbortReason(exitCode: number): string {
  if (exitCode === 2) {
    return "watchdog kill before completion target met";
  }
  if (exitCode === 3) {
    return "stuck — no filesystem progress";
  }
  if (exitCode === AGENT_FAILED_EXIT_CODE) {
    return "agent CLI exited non-zero";
  }
  if (exitCode === 4) {
    return "iteration cap without completing backlog";
  }
  return `abort exit ${String(exitCode)}`;
}

export function finalizeAgentLoopRun(
  state: RunLoopRunState,
  options: {
    readonly session: RunSession;
    readonly ports: RunLoopPorts;
    readonly logLine: (text: string) => void;
    readonly runLogPath: string;
    readonly logsDirectory: string;
    readonly iteration: number;
    readonly gateResult: CompletionGateResult;
    readonly completionDecision: CompletionResult;
    readonly gitBefore: GitSnapshot;
    readonly finalExitCode: number;
    readonly runHostVerify: boolean;
    readonly abortReason?: string;
  },
): never {
  const finishOptions: FinishRunOptions = {
    ...options,
    iterationRows: state.iterationRows,
    hookReports: state.hookReports,
    ...(state.containerProbeResult !== undefined
      ? { containerProbe: state.containerProbeResult }
      : {}),
    ...(state.lastUsage !== undefined ? { lastUsage: state.lastUsage } : {}),
  };
  return writeRunSummaryAndExit(finishOptions);
}

function writeRunSummaryAndExit(options: FinishRunOptions): never {
  const { session, ports, logLine, runLogPath, logsDirectory, iteration } = options;
  const hostGitConfigRepairs = repairHostGitConfigBoundary({
    hostWorkspacePath: session.hostWorkspacePath,
    env: process.env,
    logLine,
  });
  const gitAfter = captureGitSnapshot(session.hostWorkspacePath);
  const gitDiff = diffSnapshots(options.gitBefore, gitAfter);

  let hostVerifyResult: ReturnType<typeof runHostVerifyScript> | undefined;
  if (options.runHostVerify && session.hostVerifyScript !== undefined) {
    hostVerifyResult = runHostVerifyScript(session.hostWorkspacePath, session.hostVerifyScript);
    logLine(
      `\n host verify: ${session.hostVerifyScript} → exit ${String(hostVerifyResult.exitCode)}`,
    );
  }

  const summaryPath = join(logsDirectory, "SUMMARY.md");
  const summaryMarkdown = buildRunSummaryMarkdown({
    runId: session.runId,
    logsDirectory,
    decision: options.completionDecision,
    finalExitCode: options.finalExitCode,
    gateResult: options.gateResult,
    gitBefore: options.gitBefore,
    gitAfter,
    gitDiff,
    iterations: options.iterationRows,
    hookReports: options.hookReports,
    ...(options.containerProbe !== undefined ? { containerProbe: options.containerProbe } : {}),
    ...(options.abortReason !== undefined ? { abortReason: options.abortReason } : {}),
    ...(options.lastUsage !== undefined ? { usage: options.lastUsage } : {}),
    ...(hostVerifyResult !== undefined ? { hostVerify: hostVerifyResult } : {}),
    ...(session.completionFile !== undefined ? { completionFile: session.completionFile } : {}),
    ...(session.selfCheckFile !== undefined ? { selfCheckFile: session.selfCheckFile } : {}),
    ...(session.blockedFile !== undefined ? { blockedFile: session.blockedFile } : {}),
    ...(hostGitConfigRepairs.length > 0 ? { hostGitConfigRepairs } : {}),
  });
  ports.filesystem.writeTextFile(summaryPath, summaryMarkdown);
  logLine(`\n summary: ${summaryPath}`);

  if (gitDiff.newRootJunk.length > 0) {
    logLine(
      `${LOG_PREFIX} warning: new untracked files at repo root: ${gitDiff.newRootJunk.join(", ")}`,
    );
  }

  if (options.finalExitCode === 0) {
    logLine(formatRunComplete(iteration));
  }

  if (hostVerifyResult !== undefined && !hostVerifyResult.passed) {
    ports.console.error(
      `${LOG_PREFIX} host verify failed (exit ${HOST_VERIFY_FAILED_EXIT_CODE}) — see SUMMARY.md`,
    );
    ports.filesystem.appendTextFile(
      runLogPath,
      `host verify failed · exit=${HOST_VERIFY_FAILED_EXIT_CODE}`,
    );
    return ports.exit.exit(HOST_VERIFY_FAILED_EXIT_CODE);
  }

  if (options.finalExitCode !== 0) {
    ports.console.error(
      `${LOG_PREFIX} run ended with exit ${String(options.finalExitCode)} — see SUMMARY.md`,
    );
  }

  return ports.exit.exit(options.finalExitCode);
}
