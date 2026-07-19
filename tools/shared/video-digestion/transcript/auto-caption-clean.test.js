import { describe, expect, it } from "vitest";

import {
  cleanAutoCaptions,
  deduplicateOverlappingCues,
  formatVttCues,
  mergeProgressiveCues,
  parseCleanedVtt,
  shouldCleanAutoCaptions,
} from "./auto-caption-clean.js";

const FOUR_DIGIT_FRACTION = /\.\d{4}/u;

describe("deduplicateOverlappingCues", () => {
  it("should drop earlier cue when later cue progressively extends overlapping text", () => {
    const cues = [
      { startSec: 1.0, endSec: 2.5, text: "hello" },
      { startSec: 1.2, endSec: 3.0, text: "hello world" },
    ];

    const result = deduplicateOverlappingCues(cues);
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("hello world");
    expect(result[0].startSec).toBe(1.0);
  });

  it("should keep both cues when text differs without progressive extension", () => {
    const cues = [
      { startSec: 1.0, endSec: 2.0, text: "first topic" },
      { startSec: 1.5, endSec: 2.5, text: "second topic" },
    ];

    expect(deduplicateOverlappingCues(cues)).toHaveLength(2);
  });

  it("should collapse three-step progressive overlap to one cue", () => {
    const cues = [
      { startSec: 0.0, endSec: 1.0, text: "we" },
      { startSec: 0.2, endSec: 1.5, text: "we need" },
      { startSec: 0.4, endSec: 2.0, text: "we need to build" },
    ];

    const result = deduplicateOverlappingCues(cues);
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("we need to build");
  });
});

describe("mergeProgressiveCues", () => {
  it("should merge adjacent cues with incremental text within gap threshold", () => {
    const cues = [
      { startSec: 0.0, endSec: 0.8, text: "intro" },
      { startSec: 0.9, endSec: 1.6, text: "intro to the" },
      { startSec: 1.7, endSec: 2.5, text: "intro to the topic" },
    ];

    const result = mergeProgressiveCues(cues);
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("intro to the topic");
    expect(result[0].endSec).toBe(2.5);
  });

  it("should not merge cues separated by large time gap", () => {
    const cues = [
      { startSec: 0.0, endSec: 1.0, text: "part one" },
      { startSec: 5.0, endSec: 6.0, text: "part one extended" },
    ];

    expect(mergeProgressiveCues(cues)).toHaveLength(2);
  });
});

describe("cleanAutoCaptions", () => {
  it("should clean raw auto-caption VTT with overlapping progressive cues", () => {
    const raw = `WEBVTT

00:00:01.000 --> 00:00:02.000
hello

00:00:01.200 --> 00:00:03.000
hello world

00:00:03.500 --> 00:00:04.500
next sentence`;

    const { vtt, cues, inputCueCount, outputCueCount } = cleanAutoCaptions(raw);
    expect(inputCueCount).toBe(3);
    expect(outputCueCount).toBeLessThan(inputCueCount);
    expect(cues.some((c) => c.text === "hello world")).toBe(true);
    expect(parseCleanedVtt(vtt)).toHaveLength(outputCueCount);
  });

  it("should return empty WEBVTT for input with no cues", () => {
    const { vtt, cues, inputCueCount, outputCueCount } = cleanAutoCaptions("WEBVTT\n");
    expect(vtt).toBe("WEBVTT\n");
    expect(cues).toHaveLength(0);
    expect(inputCueCount).toBe(0);
    expect(outputCueCount).toBe(0);
  });
});

describe("shouldCleanAutoCaptions", () => {
  it("should detect progressive overlapping auto-caption pattern", () => {
    const raw = `WEBVTT

00:00:01.000 --> 00:00:02.000
alpha

00:00:01.100 --> 00:00:02.500
alpha beta`;

    expect(shouldCleanAutoCaptions(raw)).toBe(true);
  });

  it("should return false for clean non-overlapping cues", () => {
    const raw = `WEBVTT

00:00:01.000 --> 00:00:02.000
first

00:00:03.000 --> 00:00:04.000
second`;

    expect(shouldCleanAutoCaptions(raw)).toBe(false);
  });
});

describe("formatVttTimestamp carry", () => {
  it("should carry fractional seconds into the next whole second", () => {
    const vtt = formatVttCues([{ startSec: 0, endSec: 1.9996, text: "carry test" }]);
    expect(vtt).toContain("00:00:02.000");
    expect(vtt).not.toMatch(FOUR_DIGIT_FRACTION);
  });
});
