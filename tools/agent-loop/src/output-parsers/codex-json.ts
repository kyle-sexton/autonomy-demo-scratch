import type { AgentOutputParser } from "./types.js";

/** Subset of `codex exec --json` NDJSON events â€” unknown fields ignored at parse time. */
export interface CodexJsonEvent {
  readonly type?: string;
  readonly item?: {
    readonly type?: string;
    readonly text?: string;
    readonly content?: string;
  };
  readonly message?: string;
  readonly result?: string;
  readonly text?: string;
}

export function parseCodexJsonLine(line: string): CodexJsonEvent | null {
  const trimmed = line.trim();
  if (trimmed === "") {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (typeof parsed !== "object" || parsed === null) {
      return null;
    }
    return parsed as CodexJsonEvent;
  } catch {
    return null;
  }
}

function collectTextFromEvent(event: CodexJsonEvent): string | undefined {
  if (typeof event.result === "string" && event.result.length > 0) {
    return event.result;
  }
  if (typeof event.message === "string" && event.message.length > 0) {
    return event.message;
  }
  if (typeof event.text === "string" && event.text.length > 0) {
    return event.text;
  }
  const item = event.item;
  if (item !== undefined) {
    if (typeof item.text === "string" && item.text.length > 0) {
      return item.text;
    }
    if (typeof item.content === "string" && item.content.length > 0) {
      return item.content;
    }
  }
  return undefined;
}

/** Walk NDJSON stdout from `codex exec --json` for sentinel scanning. */
export function scanCodexJsonOutput(output: string): { readonly text: string } {
  const parts: string[] = [];
  let lastResult: string | undefined;

  for (const line of output.split("\n")) {
    const event = parseCodexJsonLine(line);
    if (event === null) {
      continue;
    }
    const chunk = collectTextFromEvent(event);
    if (chunk !== undefined) {
      parts.push(chunk);
      if (typeof event.result === "string") {
        lastResult = event.result;
      }
    }
  }

  if (lastResult !== undefined) {
    return { text: lastResult };
  }
  return { text: parts.join("\n") };
}

export const codexJsonOutputParser: AgentOutputParser = {
  formatLabel: "codex-json",
  referencesLogFile: true,
  extractSentinelScanText(log: string): string {
    return scanCodexJsonOutput(log).text;
  },
};
