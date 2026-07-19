import { describe, expect, it, vi } from "vitest";

import { normalizeSpawnPath, resolveSpawnInputPath, spawnAsync } from "./process.js";

describe("normalizeSpawnPath", () => {
  it("should convert backslashes to forward slashes", () => {
    expect(normalizeSpawnPath("C:\\media\\video.mp4")).toBe("C:/media/video.mp4");
  });
});

describe("resolveSpawnInputPath", () => {
  it("should pass through http URLs unchanged", () => {
    const url = "https://example.com/video.m3u8";
    expect(resolveSpawnInputPath(url)).toBe(url);
  });

  it("should expand local paths via realpath and normalize slashes", () => {
    const realpath = vi.fn(() => "C:\\media\\example\\video.mp4");
    expect(resolveSpawnInputPath("C:\\media\\EXAMPL~1\\video.mp4", { realpath })).toBe(
      "C:/media/example/video.mp4",
    );
    expect(realpath).toHaveBeenCalledWith("C:\\media\\EXAMPL~1\\video.mp4");
  });

  it("should normalize when realpath fails", () => {
    const realpath = vi.fn(() => {
      throw new Error("ENOENT");
    });
    expect(resolveSpawnInputPath("C:\\missing\\video.mp4", { realpath })).toBe(
      "C:/missing/video.mp4",
    );
  });
});

describe("spawnAsync", () => {
  it("should resolve with success for a valid command", async () => {
    const result = await spawnAsync("node", ["-e", "console.log('hello')"]);
    expect(result.success).toBe(true);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("hello");
  });

  it("should resolve with failure for a bad command", async () => {
    const result = await spawnAsync("node", ["-e", "process.exit(1)"]);
    expect(result.success).toBe(false);
    expect(result.code).toBe(1);
  });

  it("should capture stderr", async () => {
    const result = await spawnAsync("node", ["-e", "console.error('oops'); process.exit(1)"]);
    expect(result.success).toBe(false);
    expect(result.stderr).toContain("oops");
  });

  it("should timeout and kill the process", async () => {
    const result = await spawnAsync("node", ["-e", "setTimeout(() => {}, 60000)"], {
      timeout: 500,
    });
    expect(result.success).toBe(false);
    expect(result.timedOut).toBe(true);
  }, 5000);

  it("should handle spawn errors for nonexistent commands", async () => {
    const result = await spawnAsync("nonexistent-command-xyz", []);
    expect(result.success).toBe(false);
    expect(result.error).toContain("ENOENT");
  });
});
