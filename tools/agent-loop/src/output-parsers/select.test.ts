import { describe, expect, it } from "vitest";

import { codexJsonOutputParser } from "./codex-json.js";
import { grokJsonOutputParser } from "./grok-json.js";
import { plainTextOutputParser } from "./plain-text.js";
import { selectOutputParser } from "./select.js";
import { streamJsonOutputParser } from "./stream-json-parser.js";

describe("selectOutputParser", () => {
  it("should use stream-json parser for cursor and claude", () => {
    expect(selectOutputParser("cursor", "stream-json")).toBe(streamJsonOutputParser);
    expect(selectOutputParser("claude", "stream-json")).toBe(streamJsonOutputParser);
  });

  it("should use codex-json parser for codex regardless of outputFormat", () => {
    expect(selectOutputParser("codex", "stream-json")).toBe(codexJsonOutputParser);
    expect(selectOutputParser("codex", undefined)).toBe(codexJsonOutputParser);
  });

  it("should use grok-json parser for grok JSON-family formats", () => {
    expect(selectOutputParser("grok", "stream-json")).toBe(grokJsonOutputParser);
    expect(selectOutputParser("grok", "json")).toBe(grokJsonOutputParser);
  });

  it("should use plain text parser for grok text format", () => {
    expect(selectOutputParser("grok", "text")).toBe(plainTextOutputParser);
    expect(selectOutputParser("grok", undefined)).toBe(plainTextOutputParser);
  });

  it("should use plain text parser for text format on cursor", () => {
    expect(selectOutputParser("cursor", "text")).toBe(plainTextOutputParser);
    expect(selectOutputParser("cursor", undefined)).toBe(plainTextOutputParser);
  });
});
