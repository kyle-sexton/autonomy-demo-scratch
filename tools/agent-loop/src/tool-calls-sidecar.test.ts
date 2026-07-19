import { describe, expect, it } from "vitest";

import { parseToolCallNdjsonLines } from "./tool-calls-sidecar.js";

describe("parseToolCallNdjsonLines", () => {
  it("should parse tool_call events with kind, path, and hook errors", () => {
    const line = JSON.stringify({
      type: "tool_call",
      tool_call: {
        editToolCall: {
          args: { path: "/workspace/foo.md" },
          result: {
            error: { error: "Hook blocked write" },
          },
        },
      },
    });
    const events = parseToolCallNdjsonLines(line);
    expect(events).toHaveLength(1);
    expect(events[0]?.toolKind).toBe("editToolCall");
    expect(events[0]?.filePath).toBe("/workspace/foo.md");
    expect(events[0]?.hookErrors).toEqual(["Hook blocked write"]);
  });

  it("should skip non-tool_call lines and malformed json", () => {
    const events = parseToolCallNdjsonLines('{"type":"assistant"}\nnot-json\n');
    expect(events).toHaveLength(0);
  });

  it("should parse shell tool calls without hook errors", () => {
    const line = JSON.stringify({
      type: "tool_call",
      tool_call: {
        shellToolCall: { args: { command: "git status" } },
      },
    });
    const events = parseToolCallNdjsonLines(line);
    expect(events).toHaveLength(1);
    expect(events[0]?.toolKind).toBe("shellToolCall");
    expect(events[0]?.hookErrors).toEqual([]);
  });
});
