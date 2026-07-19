import { describe, expect, it } from "vitest";

import {
  deduplicateCues,
  formatTimestamp,
  formatTranscript,
  parseSubtitleManifest,
  parseVttSegment,
  processSubtitleSegments,
  stripVttInlineTags,
  vttTimestampToSeconds,
} from "./vtt-parser.js";

describe("vttTimestampToSeconds", () => {
  it("should parse HH:MM:SS.mmm format", () => {
    expect(vttTimestampToSeconds("00:01:23.456")).toBeCloseTo(83.456);
  });

  it("should parse MM:SS.mmm format", () => {
    expect(vttTimestampToSeconds("01:23.456")).toBeCloseTo(83.456);
  });

  it("should handle zero timestamp", () => {
    expect(vttTimestampToSeconds("00:00:00.000")).toBe(0);
  });

  it("should handle hours > 0", () => {
    expect(vttTimestampToSeconds("02:30:00.000")).toBe(9000);
  });

  it("should handle sub-second precision", () => {
    expect(vttTimestampToSeconds("00:00:01.500")).toBeCloseTo(1.5);
  });
});

describe("formatTimestamp", () => {
  it("should format seconds as M:SS", () => {
    expect(formatTimestamp(83)).toBe("1:23");
  });

  it("should pad seconds to two digits", () => {
    expect(formatTimestamp(5)).toBe("0:05");
  });

  it("should handle zero", () => {
    expect(formatTimestamp(0)).toBe("0:00");
  });

  it("should handle exact minutes", () => {
    expect(formatTimestamp(120)).toBe("2:00");
  });

  it("should truncate fractional seconds", () => {
    expect(formatTimestamp(83.999)).toBe("1:23");
  });
});

describe("parseVttSegment", () => {
  it("should parse a simple VTT segment with one cue", () => {
    const vtt = `WEBVTT

00:00:01.000 --> 00:00:03.000
Hello world`;

    const cues = parseVttSegment(vtt);
    expect(cues).toHaveLength(1);
    expect(cues[0].startSec).toBeCloseTo(1.0);
    expect(cues[0].endSec).toBeCloseTo(3.0);
    expect(cues[0].text).toBe("Hello world");
  });

  it("should parse multiple cues", () => {
    const vtt = `WEBVTT

00:00:01.000 --> 00:00:03.000
First cue

00:00:04.000 --> 00:00:06.000
Second cue`;

    const cues = parseVttSegment(vtt);
    expect(cues).toHaveLength(2);
    expect(cues[0].text).toBe("First cue");
    expect(cues[1].text).toBe("Second cue");
  });

  it("should join multi-line cue text with spaces", () => {
    const vtt = `WEBVTT

00:00:01.000 --> 00:00:03.000
Line one
Line two`;

    const cues = parseVttSegment(vtt);
    expect(cues).toHaveLength(1);
    expect(cues[0].text).toBe("Line one Line two");
  });

  it("should strip VTT formatting tags", () => {
    const vtt = `WEBVTT

00:00:01.000 --> 00:00:03.000
<c>Hello</c> <b>world</b>`;

    const cues = parseVttSegment(vtt);
    expect(cues).toHaveLength(1);
    expect(cues[0].text).toBe("Hello world");
  });

  it("does not create a tag when nested malformed markup is removed", () => {
    expect(stripVttInlineTags("before <scr<script>ipt> after")).toBe("before ipt> after");
  });

  it("handles a long unterminated tag in linear traversal", () => {
    const input = `<${"<".repeat(100_000)}payload`;
    expect(stripVttInlineTags(input)).toBe("");
  });

  it("should skip WEBVTT header and X-TIMESTAMP-MAP", () => {
    const vtt = `WEBVTT
X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0

00:00:01.000 --> 00:00:03.000
Content`;

    const cues = parseVttSegment(vtt);
    expect(cues).toHaveLength(1);
    expect(cues[0].text).toBe("Content");
  });

  it("should skip consecutive duplicate lines (Hotmart carry-forward)", () => {
    const vtt = `WEBVTT

00:00:01.000 --> 00:00:03.000
Same line
Same line`;

    const cues = parseVttSegment(vtt);
    expect(cues).toHaveLength(1);
    expect(cues[0].text).toBe("Same line");
  });

  it("should return empty array for segment with no cues", () => {
    const vtt = `WEBVTT
X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0`;

    expect(parseVttSegment(vtt)).toHaveLength(0);
  });

  it("should skip cues with empty text after tag stripping", () => {
    const vtt = `WEBVTT

00:00:01.000 --> 00:00:03.000
<c></c>`;

    expect(parseVttSegment(vtt)).toHaveLength(0);
  });
});

describe("deduplicateCues", () => {
  it("should remove duplicate cues with same start time and text", () => {
    const cues = [
      { startSec: 1.0, endSec: 3.0, text: "Hello" },
      { startSec: 1.0, endSec: 3.0, text: "Hello" },
    ];
    expect(deduplicateCues(cues)).toHaveLength(1);
  });

  it("should keep cues with different text at same time", () => {
    const cues = [
      { startSec: 1.0, endSec: 3.0, text: "Hello" },
      { startSec: 1.0, endSec: 3.0, text: "World" },
    ];
    expect(deduplicateCues(cues)).toHaveLength(2);
  });

  it("should normalize text for comparison (case, whitespace)", () => {
    const cues = [
      { startSec: 1.0, endSec: 3.0, text: "Hello World" },
      { startSec: 1.0, endSec: 3.0, text: "hello  world" },
    ];
    expect(deduplicateCues(cues)).toHaveLength(1);
  });

  it("should handle floating-point drift by rounding to 0.1s", () => {
    const cues = [
      { startSec: 1.001, endSec: 3.0, text: "Same" },
      { startSec: 1.002, endSec: 3.0, text: "Same" },
    ];
    expect(deduplicateCues(cues)).toHaveLength(1);
  });

  it("should sort by start time", () => {
    const cues = [
      { startSec: 5.0, endSec: 7.0, text: "Second" },
      { startSec: 1.0, endSec: 3.0, text: "First" },
    ];
    const result = deduplicateCues(cues);
    expect(result[0].text).toBe("First");
    expect(result[1].text).toBe("Second");
  });

  it("should return empty array for empty input", () => {
    expect(deduplicateCues([])).toHaveLength(0);
  });
});

describe("formatTranscript", () => {
  it("should format cues with [M:SS] timestamps", () => {
    const cues = [{ startSec: 65, endSec: 67, text: "Hello." }];
    expect(formatTranscript(cues)).toBe("[1:05] Hello.");
  });

  it("should group cues into paragraphs ending on sentence punctuation", () => {
    const cues = [
      { startSec: 0, endSec: 2, text: "First part" },
      { startSec: 3, endSec: 5, text: "second part." },
      { startSec: 6, endSec: 8, text: "New paragraph start" },
    ];
    const paragraphs = formatTranscript(cues).split("\n\n");
    expect(paragraphs).toHaveLength(2);
  });

  it("should start new paragraph on time gaps > 30s", () => {
    const cues = [
      { startSec: 0, endSec: 2, text: "Before gap" },
      { startSec: 35, endSec: 37, text: "After gap" },
    ];
    const paragraphs = formatTranscript(cues).split("\n\n");
    expect(paragraphs).toHaveLength(2);
    expect(paragraphs[1]).toContain("[0:35]");
  });

  it("should return empty string for empty cues", () => {
    expect(formatTranscript([])).toBe("");
  });

  it("should flush remaining text as final paragraph", () => {
    const cues = [{ startSec: 0, endSec: 2, text: "No punctuation" }];
    expect(formatTranscript(cues)).toBe("[0:00] No punctuation");
  });
});

describe("parseSubtitleManifest", () => {
  it("should extract .webvtt segment filenames", () => {
    const manifest = `#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.000,
seg-1.webvtt?token=abc
#EXTINF:6.000,
seg-2.webvtt?token=def
#EXT-X-ENDLIST`;

    const segments = parseSubtitleManifest(manifest);
    expect(segments).toHaveLength(2);
    expect(segments[0]).toBe("seg-1.webvtt?token=abc");
    expect(segments[1]).toBe("seg-2.webvtt?token=def");
  });

  it("should skip comment lines starting with #", () => {
    const manifest = `#EXTM3U
#EXT-X-VERSION:3
segment.webvtt`;

    expect(parseSubtitleManifest(manifest)).toHaveLength(1);
  });

  it("should skip empty lines", () => {
    const manifest = `#EXTM3U

segment.webvtt

`;
    expect(parseSubtitleManifest(manifest)).toHaveLength(1);
  });

  it("should return empty array for manifest with no segments", () => {
    expect(parseSubtitleManifest("#EXTM3U\n#EXT-X-ENDLIST")).toHaveLength(0);
  });

  it("should trim whitespace from segment lines", () => {
    const segments = parseSubtitleManifest("#EXTM3U\n  segment.webvtt  ");
    expect(segments[0]).toBe("segment.webvtt");
  });
});

describe("processSubtitleSegments", () => {
  it("should process multiple segments into a transcript", () => {
    const seg1 = `WEBVTT

00:00:01.000 --> 00:00:03.000
Hello world.`;

    const seg2 = `WEBVTT

00:00:04.000 --> 00:00:06.000
Goodbye world.`;

    const result = processSubtitleSegments([seg1, seg2]);
    expect(result.cueCount).toBe(2);
    expect(result.paragraphCount).toBeGreaterThanOrEqual(1);
    expect(result.transcript).toContain("Hello world.");
    expect(result.transcript).toContain("Goodbye world.");
  });

  it("should deduplicate overlapping segments", () => {
    const seg = `WEBVTT

00:00:01.000 --> 00:00:03.000
Overlapping cue`;

    const result = processSubtitleSegments([seg, seg]);
    expect(result.cueCount).toBe(1);
  });

  it("should return empty transcript for empty input", () => {
    const result = processSubtitleSegments([]);
    expect(result.transcript).toBe("");
    expect(result.cueCount).toBe(0);
    expect(result.paragraphCount).toBe(0);
  });
});
