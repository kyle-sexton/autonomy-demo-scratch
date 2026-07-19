import type { InContainerHooks } from "./agent-pool.js";
import { LOG_PREFIX } from "./constants.js";
import { parseToolCallNdjsonLines } from "./tool-calls-sidecar.js";

/** How a hook-block error should be interpreted for operators and automation. */
export type HookFailureKind =
  | "launcher_transport"
  | "policy_block"
  | "missing_dependency"
  | "unknown";

export interface HookFailureRecord {
  readonly toolKind: string;
  readonly filePath?: string;
  readonly rawError: string;
  readonly kind: HookFailureKind;
  readonly recommendation: string;
}

export interface IterationHookReport {
  readonly iteration: number;
  readonly iterationLabel: string;
  readonly failures: readonly HookFailureRecord[];
  readonly summary: {
    readonly total: number;
    readonly byKind: Readonly<Record<HookFailureKind, number>>;
  };
}

const HOOK_BLOCKED_PATTERN = /hook blocked/i;
const MARKDOWN_EXECUTED_AS_SHELL_PATTERN = /\.(md|mjs|json)[:/\\]/i;
const HARDCODED_PATH_PATTERN = /hardcoded machine-specific/i;
const FORMATTER_GUARD_PATTERN = /formatter guard/i;
const PLATFORM_ANALYZER_PATTERN = /PLAT\d+/i;

const KIND_RECOMMENDATIONS: Readonly<Record<HookFailureKind, string>> = {
  launcher_transport:
    "Hook stdin/launcher bug — hook script received JSON or file content as shell, not hook JSON. Check headless session bind mounts and hook config visible inside the container.",
  policy_block:
    "Real hook policy rejection — fix the edit/content the hook flagged (paths, formatters, etc.).",
  missing_dependency:
    "Hook runtime dependency missing in the container (often jq). Rebuild image or install the reported binary.",
  unknown:
    "Unclassified hook block — read raw error and iteration agent-output.log; file an issue if pattern recurs.",
};

const SUPPRESSED_LAUNCHER_TRANSPORT_RECOMMENDATION =
  "Hook block despite inContainerHooks=suppressed — session bind-mount suppression may have failed; inspect container-probe.json and pool-session-bind-mounts for this pool.";

export function recommendationForHookFailure(
  kind: HookFailureKind,
  inContainerHooks?: InContainerHooks,
): string {
  if (kind === "launcher_transport" && inContainerHooks === "suppressed") {
    return SUPPRESSED_LAUNCHER_TRANSPORT_RECOMMENDATION;
  }
  return KIND_RECOMMENDATIONS[kind];
}

/** Classify a single hook-block error string from stream-json tool sidecar output. */
export function classifyHookBlockMessage(message: string): HookFailureKind {
  const lower = message.toLowerCase();

  if (
    (lower.includes("jq:") && lower.includes("not found")) ||
    lower.includes("jq: command not found")
  ) {
    return "missing_dependency";
  }

  if (
    HARDCODED_PATH_PATTERN.test(message) ||
    FORMATTER_GUARD_PATTERN.test(message) ||
    PLATFORM_ANALYZER_PATTERN.test(message)
  ) {
    return "policy_block";
  }

  if (
    lower.includes("conversation_id") ||
    lower.includes("windows_temp_file") ||
    lower.includes("tool_input")
  ) {
    return "launcher_transport";
  }

  if (lower.includes("syntax error near unexpected token")) {
    if (message.includes("{") || message.includes("conversation_id")) {
      return "launcher_transport";
    }
  }

  if (HOOK_BLOCKED_PATTERN.test(message) && MARKDOWN_EXECUTED_AS_SHELL_PATTERN.test(message)) {
    return "launcher_transport";
  }

  return "unknown";
}

export interface AnalyzeHookFailuresOptions {
  readonly inContainerHooks?: InContainerHooks;
}

/** Parse tool-calls NDJSON and return structured hook failure records. */
export function analyzeHookFailuresFromToolCallsContent(
  content: string,
  options: AnalyzeHookFailuresOptions = {},
): HookFailureRecord[] {
  const records: HookFailureRecord[] = [];

  for (const event of parseToolCallNdjsonLines(content)) {
    for (const rawError of event.hookErrors) {
      const kind = classifyHookBlockMessage(rawError);
      records.push({
        toolKind: event.toolKind,
        ...(event.filePath !== undefined ? { filePath: event.filePath } : {}),
        rawError,
        kind,
        recommendation: recommendationForHookFailure(kind, options.inContainerHooks),
      });
    }
  }

  return records;
}

function countByKind(
  failures: readonly HookFailureRecord[],
): Readonly<Record<HookFailureKind, number>> {
  const counts: Record<HookFailureKind, number> = {
    launcher_transport: 0,
    policy_block: 0,
    missing_dependency: 0,
    unknown: 0,
  };
  for (const failure of failures) {
    counts[failure.kind] += 1;
  }
  return counts;
}

export function buildIterationHookReport(
  iteration: number,
  iterationLabel: string,
  failures: readonly HookFailureRecord[],
): IterationHookReport {
  return {
    iteration,
    iterationLabel,
    failures,
    summary: {
      total: failures.length,
      byKind: countByKind(failures),
    },
  };
}

export function formatHookObservabilityLog(report: IterationHookReport): string {
  if (report.summary.total === 0) {
    return "";
  }
  const lines = [
    `${LOG_PREFIX} hook observability · iteration ${String(report.iteration)} · ${String(report.summary.total)} block(s)`,
  ];
  for (const failure of report.failures) {
    const pathSuffix = failure.filePath !== undefined ? ` · ${failure.filePath}` : "";
    lines.push(
      `  [${failure.kind}] ${failure.toolKind}${pathSuffix}: ${failure.rawError.slice(0, 240)}`,
    );
    lines.push(`    → ${failure.recommendation}`);
  }
  return lines.join("\n");
}

export function formatHookFailuresMarkdown(reports: readonly IterationHookReport[]): string {
  const total = reports.reduce((sum, report) => sum + report.summary.total, 0);
  if (total === 0) {
    return "_no hook blocks detected in tool-calls sidecars_";
  }

  const lines: string[] = [];
  for (const report of reports) {
    if (report.failures.length === 0) {
      continue;
    }
    lines.push(`### Iteration ${String(report.iteration)} (${report.iterationLabel})`);
    lines.push("");
    for (const failure of report.failures) {
      const pathPart = failure.filePath !== undefined ? ` (\`${failure.filePath}\`)` : "";
      lines.push(`- **${failure.kind}** · ${failure.toolKind}${pathPart}`);
      lines.push(`  - error: ${failure.rawError.slice(0, 400)}`);
      lines.push(`  - action: ${failure.recommendation}`);
    }
    lines.push("");
  }
  return lines.join("\n").trimEnd();
}
