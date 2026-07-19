import { describe, expect, it } from "vitest";

import { fail, ok, timed } from "./result.js";

describe("ok", () => {
  it("should return success result with correct shape", () => {
    const result = ok("transcript text", "extract-transcript", { lesson: "M1L1" }, 42);

    expect(result.success).toBe(true);
    expect(result.data).toBe("transcript text");
    expect(result.error).toBeNull();
    expect(result.operation).toBe("extract-transcript");
    expect(result.context).toEqual({ lesson: "M1L1" });
    expect(result.durationMs).toBe(42);
  });

  it("should handle null context", () => {
    const result = ok("data", "op", null, 10);

    expect(result.success).toBe(true);
    expect(result.context).toBeNull();
  });

  it("should handle object data", () => {
    const data = { download: true, notes: false };
    const result = ok(data, "detect-resources", null, 5);

    expect(result.data).toEqual({ download: true, notes: false });
  });
});

describe("fail", () => {
  it("should return failure result with correct shape", () => {
    const result = fail("video player not found", "extract-hls-url", { lesson: "M3L1" }, 23);

    expect(result.success).toBe(false);
    expect(result.data).toBeNull();
    expect(result.error).toBe("video player not found");
    expect(result.operation).toBe("extract-hls-url");
    expect(result.context).toEqual({ lesson: "M3L1" });
    expect(result.durationMs).toBe(23);
  });

  it("should handle null context", () => {
    const result = fail("error msg", "op", null, 1);

    expect(result.success).toBe(false);
    expect(result.context).toBeNull();
  });
});

describe("timed", () => {
  it("should measure duration and return ok on success", async () => {
    const result = await timed("extract-transcript", { lesson: "M1L1" }, async () => {
      return "transcript content";
    });

    expect(result.success).toBe(true);
    expect(result.data).toBe("transcript content");
    expect(result.operation).toBe("extract-transcript");
    expect(result.context).toEqual({ lesson: "M1L1" });
    expect(result.durationMs).toBeGreaterThanOrEqual(0);
  });

  it("should catch errors and return fail result", async () => {
    const result = await timed("extract-hls-url", null, async () => {
      throw new Error("player not found");
    });

    expect(result.success).toBe(false);
    expect(result.data).toBeNull();
    expect(result.error).toBe("player not found");
    expect(result.operation).toBe("extract-hls-url");
    expect(result.durationMs).toBeGreaterThanOrEqual(0);
  });

  it("should handle non-Error throws", async () => {
    const result = await timed("op", null, async () => {
      throw new Error("string error");
    });

    expect(result.success).toBe(false);
    expect(result.error).toBe("string error");
  });

  it("should measure actual elapsed time", async () => {
    const result = await timed("slow-op", null, async () => {
      await new Promise((r) => setTimeout(r, 50));
      return "done";
    });

    expect(result.success).toBe(true);
    expect(result.durationMs).toBeGreaterThanOrEqual(40);
  });
});
