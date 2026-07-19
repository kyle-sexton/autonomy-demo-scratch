import { describe, expect, it } from "vitest";

import {
  extractStreamResultText,
  extractStreamUsage,
  extractToolSidecarLines,
  parseStreamJsonLine,
  scanStreamJsonOutput,
} from "./stream-json-terminal-result.js";

describe("parseStreamJsonLine", () => {
  it("should parse a tool_call started event", () => {
    const line =
      '{"type":"tool_call","subtype":"started","call_id":"abc","tool_call":{"readToolCall":{"args":{"path":"a.txt"}}}}';
    const event = parseStreamJsonLine(line);
    expect(event?.type).toBe("tool_call");
    expect(event?.subtype).toBe("started");
    expect(event?.call_id).toBe("abc");
  });

  it("should return null for blank or invalid lines", () => {
    expect(parseStreamJsonLine("")).toBeNull();
    expect(parseStreamJsonLine("not json")).toBeNull();
    expect(parseStreamJsonLine('{"noType":true}')).toBeNull();
  });
});

describe("extractToolSidecarLines", () => {
  it("should collect only tool_call NDJSON lines", () => {
    const output = [
      '{"type":"assistant","message":{"content":[{"text":"hi"}]}}',
      '{"type":"tool_call","subtype":"started","call_id":"1"}',
      '{"type":"tool_call","subtype":"completed","call_id":"1"}',
      '{"type":"result","result":"done"}',
    ].join("\n");

    expect(extractToolSidecarLines(output)).toEqual([
      '{"type":"tool_call","subtype":"started","call_id":"1"}',
      '{"type":"tool_call","subtype":"completed","call_id":"1"}',
    ]);
  });
});

describe("extractStreamUsage", () => {
  it("should read usage from the terminal result event", () => {
    const output = [
      '{"type":"assistant","message":{}}',
      '{"type":"result","result":"ok","usage":{"inputTokens":10,"outputTokens":5}}',
    ].join("\n");

    expect(extractStreamUsage(output)).toEqual({ inputTokens: 10, outputTokens: 5 });
  });
});

describe("scanStreamJsonOutput", () => {
  it("should collect result, usage, and tool sidecar lines in one pass", () => {
    const output = [
      '{"type":"tool_call","subtype":"started","call_id":"1"}',
      '{"type":"result","result":"ok","usage":{"inputTokens":3}}',
    ].join("\n");

    expect(scanStreamJsonOutput(output)).toEqual({
      resultText: "ok",
      usage: { inputTokens: 3 },
      toolSidecarLines: ['{"type":"tool_call","subtype":"started","call_id":"1"}'],
    });
  });
});

describe("extractStreamResultText", () => {
  it("should read the final result string from stream-json", () => {
    const output = [
      '{"type":"assistant","message":{"content":[{"text":"partial"}]}}',
      '{"type":"result","result":"<promise>NO_MORE_TASKS</promise>"}',
    ].join("\n");

    expect(extractStreamResultText(output)).toBe("<promise>NO_MORE_TASKS</promise>");
  });
});
