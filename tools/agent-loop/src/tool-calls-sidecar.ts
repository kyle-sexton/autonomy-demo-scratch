export interface ToolCallNdjsonEvent {
  readonly toolCall: Record<string, unknown>;
  readonly toolKind: string;
  readonly filePath?: string;
  readonly hookErrors: readonly string[];
}

function extractToolKind(toolCall: Record<string, unknown>): string {
  for (const key of Object.keys(toolCall)) {
    if (key.endsWith("ToolCall")) {
      return key;
    }
  }
  return "unknown";
}

function extractFilePath(toolCall: Record<string, unknown>): string | undefined {
  for (const key of Object.keys(toolCall)) {
    const inner = toolCall[key] as { args?: { path?: string; file_path?: string } } | undefined;
    const path = inner?.args?.path ?? inner?.args?.file_path;
    if (typeof path === "string" && path.length > 0) {
      return path;
    }
  }
  return undefined;
}

function extractHookErrors(toolCall: Record<string, unknown>): string[] {
  const errors: string[] = [];
  for (const key of Object.keys(toolCall)) {
    const inner = toolCall[key] as { result?: { error?: { error?: string } } } | undefined;
    const err = inner?.result?.error?.error;
    if (typeof err === "string" && err.length > 0) {
      errors.push(err);
    }
  }
  return errors;
}

/** Parse stream-json tool-calls NDJSON into structured per-line events. */
export function parseToolCallNdjsonLines(content: string): ToolCallNdjsonEvent[] {
  const events: ToolCallNdjsonEvent[] = [];

  for (const raw of content.split("\n")) {
    if (raw.trim() === "") {
      continue;
    }
    try {
      const parsed = JSON.parse(raw) as {
        type?: string;
        tool_call?: Record<string, unknown>;
      };
      if (parsed.type !== "tool_call" || parsed.tool_call === undefined) {
        continue;
      }
      const toolCall = parsed.tool_call;
      const filePath = extractFilePath(toolCall);
      events.push({
        toolCall,
        toolKind: extractToolKind(toolCall),
        ...(filePath !== undefined ? { filePath } : {}),
        hookErrors: extractHookErrors(toolCall),
      });
    } catch {
      // skip malformed lines
    }
  }

  return events;
}
