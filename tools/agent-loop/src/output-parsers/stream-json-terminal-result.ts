/**
 * NDJSON stream where the terminal `result` event holds the canonical answer.
 * Shared by Cursor and Claude Code headless when `--output-format stream-json`.
 */

/** Subset of stream-json events â€” unknown fields ignored at parse time. */
export interface StreamJsonTerminalEvent {
  readonly type: string;
  readonly subtype?: string;
  readonly call_id?: string;
  readonly tool_call?: unknown;
  readonly result?: string;
  readonly usage?: Record<string, unknown>;
  readonly duration_ms?: number;
  readonly timestamp_ms?: number;
}

export interface StreamJsonScanResult {
  readonly resultText?: string;
  readonly usage?: Record<string, unknown>;
  readonly toolSidecarLines: readonly string[];
}

export function parseStreamJsonLine(line: string): StreamJsonTerminalEvent | null {
  const trimmed = line.trim();
  if (trimmed === "") {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (typeof parsed !== "object" || parsed === null) {
      return null;
    }
    const event = parsed as StreamJsonTerminalEvent;
    if (typeof event.type !== "string") {
      return null;
    }
    return event;
  } catch {
    return null;
  }
}

/** Single-pass walk â€” collects terminal result, latest usage, and tool_call sidecar lines. */
export function scanStreamJsonOutput(output: string): StreamJsonScanResult {
  const toolSidecarLines: string[] = [];
  let resultText: string | undefined;
  let usage: Record<string, unknown> | undefined;

  for (const line of output.split("\n")) {
    const event = parseStreamJsonLine(line);
    if (event === null) {
      continue;
    }
    if (event.type === "tool_call") {
      toolSidecarLines.push(line.trim());
      continue;
    }
    if (event.type === "result") {
      if (typeof event.result === "string") {
        resultText = event.result;
      }
      if (event.usage !== undefined) {
        usage = event.usage;
      }
    }
  }

  return {
    ...(resultText !== undefined ? { resultText } : {}),
    ...(usage !== undefined ? { usage } : {}),
    toolSidecarLines,
  };
}

export function extractToolSidecarLines(output: string): string[] {
  return [...scanStreamJsonOutput(output).toolSidecarLines];
}

export function extractStreamUsage(output: string): Record<string, unknown> | undefined {
  return scanStreamJsonOutput(output).usage;
}

/** Canonical final answer from the terminal `result` event. */
export function extractStreamResultText(output: string): string | undefined {
  return scanStreamJsonOutput(output).resultText;
}
