import type { InContainerHooks } from "./agent-pool.js";
import { decideCompletion } from "./completion.js";
import {
  type CompletionGateConfig,
  countCompletionProgress,
  evaluateCompletionGates,
} from "./completion-gates.js";
import { AGENT_FAILED_EXIT_CODE, LOG_PREFIX } from "./constants.js";
import type { ContainerRuntime } from "./container-runtime.js";
import {
  formatIterationLabel,
  iterationAgentOutputLogPath,
  iterationMetaPath as iterationMetaFilePath,
  iterationToolCallsPath,
} from "./iteration-artifacts.js";
import { buildIterationContainerSnapshot, buildIterationMeta } from "./iteration-meta.js";
import { runSingleIteration } from "./iteration-runner.js";
import { buildFailureRecoveryGuide } from "./operator-recovery.js";
import type { AgentOutputParser } from "./output-parsers/types.js";
import type { RunLoopPorts } from "./ports.js";
import {
  formatAgentFailureOperatorGuidance,
  formatAgentOutputBlock,
  formatAgentOutputReference,
  formatIterationResult,
  formatIterationStart,
  parseUsageRecord,
} from "./run-console.js";
import { persistHookReportFromToolCalls } from "./run-loop-observability.js";
import type { RunLoopRunState } from "./run-loop-run-state.js";
import { parseSentinel } from "./sentinel.js";
import type { AgentCliAdapter, RunSession } from "./types.js";
import { clearStaleWorktreeIndexLock } from "./workspace-git-bridge/clear-stale-index-lock.js";

type IterationOutcomeDecision =
  | { readonly kind: "continue" }
  | { readonly kind: "done" }
  | { readonly kind: "abort"; readonly exitCode: number };

function handleIterationOutcome(options: {
  readonly iteration: number;
  readonly watchdogTriggered: boolean;
  readonly elapsedMs: number;
  readonly decision: ReturnType<typeof decideCompletion>["decision"];
  readonly logLine: (text: string) => void;
  readonly ports: RunLoopPorts;
  readonly runLogPath: string;
  readonly agentFailureGuidance?: string;
}): IterationOutcomeDecision {
  const {
    iteration,
    watchdogTriggered,
    elapsedMs,
    decision,
    logLine,
    ports,
    runLogPath,
    agentFailureGuidance,
  } = options;

  if (watchdogTriggered && decision !== "done") {
    ports.console.error(
      `${LOG_PREFIX} iteration ${iteration} watchdog kill after ${elapsedMs}ms — aborting.`,
    );
    ports.filesystem.appendTextFile(
      runLogPath,
      `watchdog kill · iteration=${iteration} · ${elapsedMs}ms`,
    );
    return { kind: "abort", exitCode: 2 };
  }

  if (watchdogTriggered && decision === "done") {
    logLine(
      `${LOG_PREFIX} iteration ${iteration} watchdog fired but completion target met on disk — fs-before-abort exit 0.`,
    );
  }

  if (decision === "done") {
    return { kind: "done" };
  }
  if (decision === "stuck") {
    ports.console.error(`${LOG_PREFIX} stuck at iteration ${iteration} — aborting.`);
    ports.filesystem.appendTextFile(runLogPath, `run stuck · iteration=${iteration}`);
    return { kind: "abort", exitCode: 3 };
  }
  if (decision === "failed") {
    if (agentFailureGuidance !== undefined) {
      ports.console.error(agentFailureGuidance);
      ports.filesystem.appendTextFile(runLogPath, agentFailureGuidance);
    }
    ports.console.error(
      `${LOG_PREFIX} agent failed at iteration ${iteration} — aborting (exit ${AGENT_FAILED_EXIT_CODE}). Review logs; discuss model/prompt before re-run.`,
    );
    ports.filesystem.appendTextFile(runLogPath, `run agent-failed · iteration=${iteration}`);
    return { kind: "abort", exitCode: AGENT_FAILED_EXIT_CODE };
  }

  return { kind: "continue" };
}

export interface IterationInput {
  readonly iter: number;
  readonly maxIterations: number;
  readonly session: RunSession;
  readonly prompt: string;
  readonly adapter: AgentCliAdapter;
  readonly containerRuntime: ContainerRuntime;
  readonly gateConfig: CompletionGateConfig;
  readonly ports: RunLoopPorts;
  readonly logsDirectory: string;
  readonly runLogPath: string;
  readonly logLine: (text: string) => void;
  readonly outputParser: AgentOutputParser;
  readonly inContainerHooks: InContainerHooks;
  readonly state: RunLoopRunState;
  readonly hostWorkspacePath: string;
  readonly containerWorkspaceMount: string;
  readonly completionOutSubdir: string;
  readonly completionTarget: number;
  readonly completionFile?: string;
  readonly resolvedModelSlug: string;
}

export type IterationOutcome =
  | { readonly kind: "continue" }
  | {
      readonly kind: "terminal";
      readonly finalExitCode: number;
      readonly runHostVerify: boolean;
      readonly gateResult: ReturnType<typeof evaluateCompletionGates>;
      readonly completionDecision: ReturnType<typeof decideCompletion>;
    };

export async function executeAgentLoopIteration(input: IterationInput): Promise<IterationOutcome> {
  const {
    iter,
    maxIterations,
    session,
    prompt,
    adapter,
    containerRuntime,
    gateConfig,
    ports,
    logsDirectory,
    runLogPath,
    logLine,
    outputParser,
    inContainerHooks,
    state,
    hostWorkspacePath,
    containerWorkspaceMount,
    completionOutSubdir,
    completionTarget,
    completionFile,
    resolvedModelSlug,
  } = input;
  const { agentCli } = session;

  const before = countCompletionProgress(gateConfig);
  const iterLabel = formatIterationLabel(iter, agentCli);
  const iterLogPath = iterationAgentOutputLogPath(logsDirectory, iterLabel);
  const iterMetaPath = iterationMetaFilePath(logsDirectory, iterLabel);
  const iterToolsPath = iterationToolCallsPath(logsDirectory, iterLabel);

  ports.filesystem.writeTextFile(iterLogPath, "");

  logLine(
    formatIterationStart({
      iteration: iter,
      cap: maxIterations,
    }),
  );

  clearStaleWorktreeIndexLock(hostWorkspacePath);

  const iteration = await runSingleIteration({
    session,
    iteration: iter,
    prompt,
    adapter,
    containerRuntime,
    runtimeOptions: {
      onOutputChunk: (chunk) => {
        ports.filesystem.appendRawTextFile(iterLogPath, chunk);
      },
    },
  });

  logLine(` container:  ${iteration.containerName}`);

  const sentinelLog = outputParser.extractSentinelScanText(iteration.log);
  const sentinel = parseSentinel(sentinelLog);
  const agentFailed = iteration.exitCode !== null && iteration.exitCode !== 0;
  const usageRaw = outputParser.extractUsage?.(iteration.log);
  const usage = parseUsageRecord(usageRaw);
  if (usage !== undefined) {
    state.lastUsage = usage;
  }

  ports.filesystem.writeTextFile(
    iterMetaPath,
    `${JSON.stringify(
      buildIterationMeta({
        elapsedMs: iteration.elapsedMs,
        exitCode: iteration.exitCode,
        signal: iteration.signal,
        killReason: iteration.killReason,
        sentinel,
        watchdogTriggered: iteration.watchdogTriggered,
        completionGraceEnd: iteration.completionGraceEnd,
        ...(usageRaw !== undefined ? { usage: usageRaw } : {}),
        container: buildIterationContainerSnapshot(
          session,
          iteration,
          hostWorkspacePath,
          containerWorkspaceMount,
        ),
      }),
      null,
      2,
    )}\n`,
  );

  if (outputParser.referencesLogFile) {
    const toolLines = outputParser.extractToolSidecarLines?.(iteration.log) ?? [];
    if (toolLines.length > 0) {
      ports.filesystem.writeTextFile(iterToolsPath, `${toolLines.join("\n")}\n`);
      const hookReport = persistHookReportFromToolCalls({
        ports,
        logsDirectory,
        iteration: iter,
        iterLabel,
        toolLines,
        logLine,
        inContainerHooks,
      });
      if (hookReport !== undefined) {
        state.hookReports.push(hookReport);
      }
    }
    logLine(formatAgentOutputReference(iter, iterLogPath, outputParser.formatLabel));
  } else {
    logLine(formatAgentOutputBlock(iter, iteration.log, iterLogPath));
  }

  if (iteration.completionGraceEnd) {
    logLine(
      `${LOG_PREFIX} iteration ${iter} completion grace expired after sentinel — proceeding with decideCompletion.`,
    );
  }

  const after = countCompletionProgress(gateConfig);
  const gateResult = evaluateCompletionGates(gateConfig, before, after);

  const decision = decideCompletion({
    sentinel: agentFailed ? null : sentinel,
    fsComplete: gateResult.fsComplete,
    progressed: gateResult.progressed,
    ...(agentFailed ? { agentFailed: true, agentExitCode: iteration.exitCode } : {}),
  });
  state.lastGateResult = gateResult;
  state.lastCompletionDecision = decision;
  state.iterationRows.push({
    iteration: iter,
    elapsedMs: iteration.elapsedMs,
    sentinel,
    exitCode: iteration.exitCode,
  });

  logLine(
    formatIterationResult({
      iteration: iter,
      tool: agentCli,
      outSubdir: completionOutSubdir,
      before,
      after,
      target: completionFile !== undefined ? 1 : completionTarget,
      ...(completionFile !== undefined ? { completionFile } : {}),
      gateReason: gateResult.reason,
      sentinel,
      decision: decision.decision,
      reason: decision.reason,
      elapsedMs: iteration.elapsedMs,
      ...(usage !== undefined ? { usage } : {}),
    }),
  );

  const outcome = handleIterationOutcome({
    iteration: iter,
    watchdogTriggered: iteration.watchdogTriggered,
    elapsedMs: iteration.elapsedMs,
    decision: decision.decision,
    logLine,
    ports,
    runLogPath,
    ...(decision.decision === "failed"
      ? {
          agentFailureGuidance: formatAgentFailureOperatorGuidance({
            iteration: iter,
            exitCode: iteration.exitCode,
            iterLogPath,
            guide: buildFailureRecoveryGuide(agentCli, resolvedModelSlug),
          }),
        }
      : {}),
  });

  if (outcome.kind === "continue") {
    return { kind: "continue" };
  }

  if (outcome.kind === "done") {
    return {
      kind: "terminal",
      finalExitCode: 0,
      runHostVerify: true,
      gateResult,
      completionDecision: decision,
    };
  }

  return {
    kind: "terminal",
    finalExitCode: outcome.exitCode,
    runHostVerify: false,
    gateResult: state.lastGateResult,
    completionDecision: state.lastCompletionDecision,
  };
}
