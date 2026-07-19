import { describe, expect, it } from "vitest";

import {
  cleanManualCaptions,
  collapseRollingDuplicatePhrases,
  stripCaptionHtmlEntities,
} from "./manual-caption-clean.js";

const TRIPLICATED_HELLO_RE = /hello hello hello/;

describe("stripCaptionHtmlEntities", () => {
  it("replaces nbsp", () => {
    expect(stripCaptionHtmlEntities("hello&nbsp;world")).toBe("hello world");
  });

  it("decodes exactly one entity layer", () => {
    expect(stripCaptionHtmlEntities("&amp;lt;script&amp;gt;")).toBe("&lt;script&gt;");
  });

  it("decodes entity names case-insensitively", () => {
    expect(stripCaptionHtmlEntities("A&NBSP;B &LT; C")).toBe("A B < C");
  });
});

describe("collapseRollingDuplicatePhrases", () => {
  it("collapses triplicated phrase runs", () => {
    const input = "I just listened I just listened I just listened to Karpathy";
    expect(collapseRollingDuplicatePhrases(input)).toBe("I just listened to Karpathy");
  });
});

describe("cleanManualCaptions", () => {
  it("returns deduplicated cues", () => {
    const vtt = `WEBVTT

00:00:01.000 --> 00:00:05.000
hello hello hello world
`;
    const result = cleanManualCaptions(vtt);
    expect(result.cleanedManualCaptions).toBe(true);
    expect(result.cues[0].text).toContain("hello");
    expect(result.cues[0].text).not.toMatch(TRIPLICATED_HELLO_RE);
  });
});
