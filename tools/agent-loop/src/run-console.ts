import type { FailureRecoveryGuide } from "./operator-recovery.js";
import { modelOverrideEnvVarName } from "./operator-recovery.js";

const RULE = "─".repeat(72);
const HEADER_RULE = "═".repeat(72);

/** Align banner field values in a fixed column (excludes leading indent space). */
const BANNER_LABEL_WIDTH = 14;

function formatBannerLine(label: string, value: string): string {
  return ` ${label.padEnd(BANNER_LABEL_WIDTH)} ${value}`;
}

export interface RunBannerParams {
  readonly runId: string;
  readonly tool: string;
  readonly workspacePath: string;
  readonly workspaceSlug: string;
  readonly promptPath: string;
  readonly target: number;
  readonly outSubdir: string;
  readonly cap: number;
  readonly runLogPath: string;
  readonly model?: string;
  readonly completionFile?: string;
  readonly hostVerifyScript?: string;
}

export function formatRunBanner(params: RunBannerParams): string {
  return `${[
    HEADER_RULE,
    " agent-loop run",
    HEADER_RULE,
    formatBannerLine("run id:", params.runId),
    formatBannerLine("tool:", params.tool),
    ...(params.model !== undefined ? [formatBannerLine("model:", params.model)] : []),
    formatBannerLine("workspace:", params.workspacePath),
    formatBannerLine("slug:", params.workspaceSlug),
    formatBannerLine("prompt:", params.promptPath),
    formatBannerLine(
      "completion:",
      params.completionFile !== undefined
        ? params.completionFile
        : `${params.target} file(s) in ${params.outSubdir}/`,
    ),
    ...(params.hostVerifyScript !== undefined
      ? [formatBannerLine("host verify:", params.hostVerifyScript)]
      : []),
    formatBannerLine("cap:", `${params.cap} iteration(s) max`),
    formatBannerLine("orchestrator log:", params.runLogPath),
    RULE,
  ].join("\n")}\n`;
}

/** Prefix a log section after the run banner or a prior section (single blank line). */
function logSection(lines: readonly string[]): string {
  return `\n${lines.join("\n")}`;
}

export interface IterationStartParams {
  readonly iteration: number;
  readonly cap: number;
  readonly containerName?: string;
}

export function formatIterationStart(params: IterationStartParams): string {
  const containerLine =
    params.containerName !== undefined
      ? ` container:  ${params.containerName}`
      : " container:  (pending)";
  return logSection([
    RULE,
    ` iteration ${params.iteration}/${params.cap}`,
    containerLine,
    " status:     spawning…",
    RULE,
  ]);
}

export function formatAgentOutputBlock(
  iteration: number,
  log: string,
  iterLogPath: string,
): string {
  const body = log.trimEnd() === "" ? "<empty>" : log.trimEnd();
  return logSection([
    ` agent output (iteration ${iteration}, file: ${iterLogPath}):`,
    RULE,
    body,
    RULE,
  ]);
}

export function formatAgentOutputReference(
  iteration: number,
  iterLogPath: string,
  formatLabel: string,
): string {
  return logSection([
    ` agent output (iteration ${iteration}): see ${iterLogPath} (${formatLabel} — not duplicated in orchestrator.log)`,
    RULE,
  ]);
}

export function parseUsageRecord(
  usage: Record<string, unknown> | undefined,
): TokenUsageLine | undefined {
  if (usage === undefined) {
    return undefined;
  }
  return {
    ...(typeof usage["inputTokens"] === "number" ? { inputTokens: usage["inputTokens"] } : {}),
    ...(typeof usage["outputTokens"] === "number" ? { outputTokens: usage["outputTokens"] } : {}),
    ...(typeof usage["cacheReadTokens"] === "number"
      ? { cacheReadTokens: usage["cacheReadTokens"] }
      : {}),
    ...(typeof usage["cacheWriteTokens"] === "number"
      ? { cacheWriteTokens: usage["cacheWriteTokens"] }
      : {}),
  };
}

export interface TokenUsageLine {
  readonly inputTokens?: number;
  readonly outputTokens?: number;
  readonly cacheReadTokens?: number;
  readonly cacheWriteTokens?: number;
}

export interface IterationResultParams {
  readonly iteration: number;
  readonly tool: string;
  readonly outSubdir: string;
  readonly before: number;
  readonly after: number;
  readonly target: number;
  readonly completionFile?: string;
  readonly gateReason?: string;
  readonly sentinel: string | null;
  readonly decision: string;
  readonly reason: string;
  readonly elapsedMs: number;
  readonly usage?: TokenUsageLine;
}

export function formatIterationResult(params: IterationResultParams): string {
  const progressLine =
    params.completionFile !== undefined
      ? `   progress:  ${params.completionFile} ${params.after >= 1 ? "present" : "missing"}`
      : `   progress:  ${params.outSubdir}/ ${params.before} → ${params.after}/${params.target}`;
  const usageLine =
    params.usage !== undefined
      ? `   tokens:    in=${String(params.usage.inputTokens ?? "?")} out=${String(params.usage.outputTokens ?? "?")} cacheRead=${String(params.usage.cacheReadTokens ?? "?")}`
      : undefined;
  return logSection([
    " result:",
    progressLine,
    ...(params.gateReason !== undefined ? [`   gate:      ${params.gateReason}`] : []),
    `   sentinel:  ${params.sentinel ?? "<none>"}`,
    `   decision:  ${params.decision} — ${params.reason}`,
    `   elapsed:   ${params.elapsedMs}ms`,
    ...(usageLine !== undefined ? [usageLine] : []),
  ]);
}

export function formatRunComplete(iterations: number): string {
  return logSection([HEADER_RULE, ` run complete — ${iterations} iteration(s)`, HEADER_RULE]);
}

export interface AgentFailureGuidanceParams {
  readonly iteration: number;
  readonly exitCode: number | null;
  readonly iterLogPath: string;
  readonly guide: FailureRecoveryGuide;
}

/** Operator-facing recovery steps — orchestrator does not auto-retry or switch models. */
export function formatAgentFailureOperatorGuidance(params: AgentFailureGuidanceParams): string {
  const codeLabel = params.exitCode === null ? "null" : String(params.exitCode);
  const modelEnv = modelOverrideEnvVarName();
  const { guide } = params;
  return logSection([
    " agent failed — operator review required (no auto-continue):",
    `   iteration:     ${params.iteration}`,
    `   exit code:     ${codeLabel}`,
    `   tool:          ${guide.agentCli}`,
    `   model used:    ${guide.modelUsed}`,
    `   agent log:     ${params.iterLogPath}`,
    "",
    "   Next steps (discuss before re-running):",
    "   1. Read the agent log — rate limits, auth, and tool errors surface there.",
    "   2. Decide whether to adjust the prompt, scope, or model.",
    `   3. Lower-cost profile for this tool: role "mechanical" → ${guide.mechanicalRoleModelSlug}`,
    `      (run.local.json role "mechanical" or ${modelEnv}=<slug>)`,
    "   4. Re-invoke the orchestrator only after explicit operator go-ahead.",
  ]);
}
