import { describe, expect, it } from "vitest";

import { extractGrokScanText, scanGrokJsonOutput } from "./grok-json.js";

describe("scanGrokJsonOutput", () => {
  it("should parse json output-format text wrapper", () => {
    const inner = { posts: [{ t: "hi", u: "https://x.com/x/status/1", d: "2026-06-01" }] };
    const raw = JSON.stringify({ text: JSON.stringify(inner), stopReason: "EndTurn" });
    expect(scanGrokJsonOutput(raw).text).toBe(JSON.stringify(inner));
  });

  it("should parse NDJSON streaming lines", () => {
    const raw = [
      JSON.stringify({ type: "chunk", text: "partial" }),
      JSON.stringify({ text: "DONE sentinel body", stopReason: "EndTurn" }),
    ].join("\n");
    expect(extractGrokScanText(raw)).toBe("DONE sentinel body");
  });
});
