import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import imghash from "imghash";
import { describe, expect, it, vi } from "vitest";

import {
  DEFAULT_MAX_HAMMING_DISTANCE,
  deduplicateFrames,
  hammingDistanceHex,
  isIntervalFrame,
  toFrameCandidate,
} from "./dedup.js";

const FIXTURES_DIR = join(dirname(fileURLToPath(import.meta.url)), "fixtures");

describe("hammingDistanceHex", () => {
  it("should return zero for identical hashes", () => {
    const hash = "f884c4d8d1193c07";
    expect(hammingDistanceHex(hash, hash)).toBe(0);
  });

  it("should count differing bits between hashes", () => {
    const a = imghash.hexToBinary("ff");
    const b = imghash.hexToBinary("00");
    expect(hammingDistanceHex("ff", "00")).toBe(
      a.split("").filter((bit, i) => bit !== b[i]).length,
    );
  });
});

describe("isIntervalFrame", () => {
  it("should detect interval capture prefixes", () => {
    expect(isIntervalFrame("interval_0001.png")).toBe(true);
    expect(isIntervalFrame("scene_0001.png")).toBe(false);
  });
});

describe("toFrameCandidate", () => {
  it("should derive interval flag from basename", () => {
    const candidate = toFrameCandidate("/tmp/interval_0002.png");
    expect(candidate.file).toBe("interval_0002.png");
    expect(candidate.isInterval).toBe(true);
    expect(candidate.likelyDuplicate).toBe(false);
  });
});

describe("deduplicateFrames", () => {
  it("should mark identical fixture images as duplicates with fake hashes", async () => {
    const hashImage = vi.fn(async (path) => {
      if (path.includes("solid-red-dup")) return "aaaaaaaaaaaaaaaa";
      if (path.includes("solid-red")) return "aaaaaaaaaaaaaaaa";
      return "bbbbbbbbbbbbbbbb";
    });

    const framePaths = [
      join(FIXTURES_DIR, "solid-red.png"),
      join(FIXTURES_DIR, "solid-red-dup.png"),
      join(FIXTURES_DIR, "solid-blue.png"),
    ];

    const result = await deduplicateFrames(
      framePaths,
      { maxHammingDistance: DEFAULT_MAX_HAMMING_DISTANCE },
      { hashImage, log: { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() } },
    );

    expect(result.total).toBe(3);
    expect(result.duplicates).toBe(1);
    expect(result.unique).toHaveLength(2);
    expect(result.frames[1].likelyDuplicate).toBe(true);
    expect(result.frames[2].likelyDuplicate).toBe(false);
  });

  it("should hash real fixture PNGs when hashImage is not injected", async () => {
    const framePaths = [
      join(FIXTURES_DIR, "solid-red.png"),
      join(FIXTURES_DIR, "solid-red-dup.png"),
    ];

    const result = await deduplicateFrames(
      framePaths,
      {
        maxHammingDistance: DEFAULT_MAX_HAMMING_DISTANCE,
      },
      {
        log: { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() },
      },
    );

    expect(result.frames[0].phash).toBeTruthy();
    expect(result.frames[1].phash).toBeTruthy();
    expect(hammingDistanceHex(result.frames[0].phash, result.frames[1].phash)).toBeLessThanOrEqual(
      DEFAULT_MAX_HAMMING_DISTANCE,
    );
    expect(result.duplicates).toBe(1);
  }, 30_000);
});
