import type { AgentOutputParser } from "./types.js";

/** Subset of Grok `--output-format json` / `streaming-json` events. */
export interface GrokJsonEvent {
  readonly text?: string;
  readonly result?: string;
  readonly output?: string;
  readonly content?: string;
  readonly message?: string;
  readonly stopReason?: string;
  readonly type?: string;
}

export function parseGrokJsonLine(line: string): GrokJsonEvent | null {
  const trimmed = line.trim();
  if (trimmed === "" || trimmed.startsWith("error:")) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (typeof parsed !== "object" || parsed === null) {
      return null;
    }
    return parsed as GrokJsonEvent;
  } catch {
    return null;
  }
}

function collectTextFromEvent(event: GrokJsonEvent): string | undefined {
  const candidates = [event.text, event.result, event.output, event.content, event.message];
  for (const value of candidates) {
    if (typeof value === "string" && value.trim().length > 0) {
      return value;
    }
  }
  return undefined;
}

/** Walk Grok headless stdout (single JSON object or NDJSON stream). */
export function scanGrokJsonOutput(output: string): { readonly text: string } {
  const parts: string[] = [];
  let terminalText: string | undefined;

  for (const line of output.split("\n")) {
    const event = parseGrokJsonLine(line);
    if (event === null) {
      continue;
    }
    const chunk = collectTextFromEvent(event);
    if (chunk === undefined) {
      continue;
    }
    parts.push(chunk);
    if (event.stopReason !== undefined || event.type === "result") {
      terminalText = chunk;
    }
  }

  if (terminalText !== undefined) {
    return { text: terminalText };
  }

  const whole = output.trim();
  if (whole.startsWith("{")) {
    try {
      const event = JSON.parse(whole) as GrokJsonEvent;
      const chunk = collectTextFromEvent(event);
      if (chunk !== undefined) {
        return { text: chunk };
      }
    } catch {
      /* fall through */
    }
  }

  return { text: parts.join("\n") };
}

export function extractGrokScanText(output: string): string {
  return scanGrokJsonOutput(output).text;
}

export const grokJsonOutputParser: AgentOutputParser = {
  formatLabel: "grok-json",
  referencesLogFile: true,
  extractSentinelScanText(log: string): string {
    return extractGrokScanText(log);
  },
};
