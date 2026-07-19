import { describe, expect, it } from "vitest";

import { normalizeHostFilesystemPath } from "./host-path.js";

describe("normalizeHostFilesystemPath", () => {
  it("passes through posix paths on non-win32", () => {
    const originalPlatform = process.platform;
    Object.defineProperty(process, "platform", { value: "linux" });
    try {
      expect(normalizeHostFilesystemPath("/tmp/ws")).toBe("/tmp/ws");
    } finally {
      Object.defineProperty(process, "platform", { value: originalPlatform });
    }
  });

  it("converts MSYS /d/ paths on win32", () => {
    const originalPlatform = process.platform;
    Object.defineProperty(process, "platform", { value: "win32" });
    try {
      expect(normalizeHostFilesystemPath("/d/dev/example-org/example-repo")).toBe(
        "D:/dev/example-org/example-repo",
      );
    } finally {
      Object.defineProperty(process, "platform", { value: originalPlatform });
    }
  });

  it("normalizes backslashes on win32", () => {
    const originalPlatform = process.platform;
    Object.defineProperty(process, "platform", { value: "win32" });
    try {
      expect(normalizeHostFilesystemPath("D:\\dev\\foo")).toBe("D:/dev/foo");
    } finally {
      Object.defineProperty(process, "platform", { value: originalPlatform });
    }
  });
});
