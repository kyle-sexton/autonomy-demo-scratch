import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type { CompletionGateResult } from "./completion-gates.js";
import type { ContainerProbeResult } from "./container-probe.js";
import { formatHookFailuresMarkdown, type IterationHookReport } from "./hook-observability.js";
import type { HostVerifyResult } from "./host-verify.js";
import { tailLines } from "./host-verify.js";
import { CONTAINER_PROBE_FILENAME, ORCHESTRATOR_LOG_FILENAME } from "./iteration-artifacts.js";
import type { HostGitConfigRepair } from "./preflight/host-git-config-boundary.js";
import type { CompletionResult } from "./types.js";
import type { GitSnapshot, SnapshotDiff } from "./workspace-snapshot.js";

export interface IterationSummaryRow {
  readonly iteration: number;
  readonly elapsedMs: number;
  readonly sentinel: string | null;
  readonly exitCode: number | null;
}

export interface TokenUsageSummary {
  readonly inputTokens?: number;
  readonly outputTokens?: number;
  readonly cacheReadTokens?: number;
  readonly cacheWriteTokens?: number;
}

export interface RunSummaryInput {
  readonly runId: string;
  readonly logsDirectory: string;
  readonly decision: CompletionResult;
  readonly finalExitCode: number;
  readonly gateResult: CompletionGateResult;
  readonly gitBefore: GitSnapshot;
  readonly gitAfter: GitSnapshot;
  readonly gitDiff: SnapshotDiff;
  readonly iterations: readonly IterationSummaryRow[];
  readonly usage?: TokenUsageSummary;
  readonly hostVerify?: HostVerifyResult;
  readonly completionFile?: string;
  readonly selfCheckFile?: string;
  readonly blockedFile?: string;
  readonly hookReports?: readonly IterationHookReport[];
  readonly containerProbe?: ContainerProbeResult;
  readonly hostGitConfigRepairs?: readonly HostGitConfigRepair[];
  readonly abortReason?: string;
}

export interface ToolDigestLine {
  readonly kind: string;
  readonly detail: string;
}

/** Extract hook blocks, shell commands, and errors from tool-calls jsonl. */
export function digestToolCallsJsonl(content: string, maxLines = 20): ToolDigestLine[] {
  const lines: ToolDigestLine[] = [];
  for (const raw of content.split("\n")) {
    if (raw.trim() === "") {
      continue;
    }
    try {
      const event = JSON.parse(raw) as {
        type?: string;
        tool_call?: Record<string, unknown>;
      };
      if (event.type !== "tool_call") {
        continue;
      }
      const tc = event.tool_call ?? {};
      if ("shellToolCall" in tc) {
        const shell = tc["shellToolCall"] as { args?: { command?: string } };
        const cmd = shell.args?.command ?? "";
        if (cmd.length > 0) {
          lines.push({ kind: "shell", detail: cmd.slice(0, 200) });
        }
      }
      for (const key of Object.keys(tc)) {
        const inner = tc[key] as { result?: { error?: { error?: string } } };
        const err = inner.result?.error?.error;
        if (typeof err === "string" && err.length > 0) {
          lines.push({ kind: "hook-block", detail: err.slice(0, 300) });
        }
      }
    } catch {
      // skip malformed lines
    }
  }
  return lines.slice(-maxLines);
}

export function formatTokenUsage(usage: TokenUsageSummary | undefined): string {
  if (usage === undefined) {
    return "not reported";
  }
  const parts: string[] = [];
  if (usage.inputTokens !== undefined) {
    parts.push(`input=${String(usage.inputTokens)}`);
  }
  if (usage.outputTokens !== undefined) {
    parts.push(`output=${String(usage.outputTokens)}`);
  }
  if (usage.cacheReadTokens !== undefined) {
    parts.push(`cacheRead=${String(usage.cacheReadTokens)}`);
  }
  if (usage.cacheWriteTokens !== undefined) {
    parts.push(`cacheWrite=${String(usage.cacheWriteTokens)}`);
  }
  return parts.length > 0 ? parts.join(", ") : "not reported";
}

function loadToolDigestFromRunFolder(logsDirectory: string): ToolDigestLine[] {
  let files: string[] = [];
  try {
    files = readdirSync(logsDirectory).filter((name) => name.endsWith("-tool-calls.jsonl"));
  } catch {
    return [];
  }
  files.sort();
  const combined: ToolDigestLine[] = [];
  for (const file of files) {
    try {
      const raw = readFileSync(join(logsDirectory, file), "utf8");
      combined.push(...digestToolCallsJsonl(raw, 50));
    } catch {
      // skip unreadable sidecar
    }
  }
  return combined.slice(-20);
}

function formatContainerProbeSection(probe: ContainerProbeResult | undefined): string {
  if (probe === undefined) {
    return "not run";
  }
  if (probe.error !== undefined) {
    return `error: ${probe.error}`;
  }
  const depLines =
    probe.dependencies
      ?.map(
        (dep) =>
          `- ${dep.name}: ${dep.present ? `ok (${dep.version ?? "present"})` : "**MISSING**"}`,
      )
      .join("\n") ?? "_no dependency list_";
  const hookConfig = probe.hookConfig;
  const hookProbe = probe.hookProbe;
  return [
    `workspace: \`${probe.workspace ?? "unknown"}\``,
    "",
    "**Dependencies**",
    "",
    depLines,
    "",
    "**Hook config**",
    "",
    `- .cursor/hooks.json: ${hookConfig?.hasCursorHooks === true ? "present" : "missing"}${hookConfig?.cursorHooksEmpty === true ? " (empty)" : ""}`,
    `- .claude/settings.json: ${hookConfig?.hasClaudeSettings === true ? "present" : "missing"}${hookConfig?.settingsHasHooksKey === true ? " (hooks key)" : hookConfig?.settingsHasHooksKey === false ? " (no hooks key)" : ""}`,
    "",
    "**Hook dry-run** (`branch-protection.sh`)",
    "",
    `- exit: ${hookProbe?.exitCode === null || hookProbe?.exitCode === undefined ? "â€”" : String(hookProbe.exitCode)}`,
    ...(hookProbe?.stderr !== undefined && hookProbe.stderr.length > 0
      ? ["", "```", hookProbe.stderr.slice(0, 2000), "```"]
      : []),
    "",
    `Full probe: [${CONTAINER_PROBE_FILENAME}](./${CONTAINER_PROBE_FILENAME})`,
  ].join("\n");
}

export function buildRunSummaryMarkdown(input: RunSummaryInput): string {
  const toolDigest = loadToolDigestFromRunFolder(input.logsDirectory);
  const hookSection = formatHookFailuresMarkdown(input.hookReports ?? []);

  const iterTable = input.iterations
    .map(
      (row) =>
        `| ${String(row.iteration)} | ${String(row.elapsedMs)} | ${row.sentinel ?? "â€”"} | ${row.exitCode === null ? "â€”" : String(row.exitCode)} |`,
    )
    .join("\n");

  const hostVerifySection =
    input.hostVerify === undefined
      ? "not configured"
      : [
          `script: \`${input.hostVerify.scriptPath}\``,
          `exit: ${String(input.hostVerify.exitCode)}`,
          `passed: ${input.hostVerify.passed ? "yes" : "no"}`,
          "",
          "```",
          tailLines(
            [input.hostVerify.stdout, input.hostVerify.stderr]
              .filter((s) => s.length > 0)
              .join("\n"),
            40,
          ),
          "```",
        ].join("\n");

  const junkSection =
    input.gitDiff.newRootJunk.length === 0
      ? "none detected"
      : input.gitDiff.newRootJunk.map((f) => `- \`${f}\``).join("\n");

  const digestSection =
    toolDigest.length === 0
      ? "_no tool-calls sidecar or empty digest_"
      : toolDigest.map((line) => `- **${line.kind}**: ${line.detail}`).join("\n");

  return [
    `# Run summary â€” ${input.runId}`,
    "",
    "## Outcome",
    "",
    `- decision: **${input.decision.decision}**`,
    `- final exit code: **${String(input.finalExitCode)}**`,
    `- completion gate: ${input.gateResult.reason}`,
    `- blocked: ${input.gateResult.blockedPresent ? "yes" : "no"}`,
    `- self-check: ${input.gateResult.selfCheckPresent ? "present" : "missing"}`,
    ...(input.completionFile !== undefined
      ? [`- completion file: \`${input.completionFile}\``]
      : []),
    ...(input.abortReason !== undefined ? [`- abort reason: ${input.abortReason}`] : []),
    "",
    "## Tokens",
    "",
    formatTokenUsage(input.usage),
    "",
    "## Git",
    "",
    "### New untracked at repo root",
    "",
    junkSection,
    "",
    "### Status (end of run)",
    "",
    "```",
    input.gitAfter.statusShort.slice(0, 8000),
    "```",
    "",
    "### Diff stat (end of run)",
    "",
    "```",
    input.gitAfter.diffStat.slice(0, 4000),
    "```",
    "",
    ...(input.hostGitConfigRepairs !== undefined && input.hostGitConfigRepairs.length > 0
      ? [
          "### Host git config repairs (container leak cleanup)",
          "",
          input.hostGitConfigRepairs
            .map((repair) => `- \`${repair.key}\`: ${repair.action}`)
            .join("\n"),
          "",
        ]
      : []),
    "## Iterations",
    "",
    "| iter | elapsedMs | sentinel | exit |",
    "| --- | --- | --- | --- |",
    iterTable.length > 0 ? iterTable : "| â€” | â€” | â€” | â€” |",
    "",
    "## Host verify",
    "",
    hostVerifySection,
    "",
    "## Container probe",
    "",
    formatContainerProbeSection(input.containerProbe),
    "",
    "## Hook failures",
    "",
    hookSection,
    "",
    "## Tool digest",
    "",
    digestSection,
    "",
    "## Artifacts",
    "",
    `- [orchestrator.log](./${ORCHESTRATOR_LOG_FILENAME})`,
    `- [iteration agent output](./) (see iteration-*-agent-output.log in this folder)`,
    `- [tool-calls jsonl](./) (iteration-*-tool-calls.jsonl when stream-json)`,
    `- [hook reports](./) (iteration-*-hook-report.json when stream-json blocks hooks)`,
    `- [container probe](./${CONTAINER_PROBE_FILENAME}) (pre-loop environment check)`,
    `- [iteration meta](./) (iteration-*-meta.json)`,
    "",
  ].join("\n");
}
