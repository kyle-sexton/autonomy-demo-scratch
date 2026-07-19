import { describe, expect, it } from "vitest";

import {
  normalizeDockerBindMountHostPath,
  resolveDockerBindMountHostPath,
} from "./docker-host-path.js";

const RELATIVE_WORKSPACE_SUFFIX_REGEX = /relative[\\/]workspace$/u;

describe("normalizeDockerBindMountHostPath", () => {
  it("should normalize Windows backslashes to forward slashes", () => {
    expect(normalizeDockerBindMountHostPath("C:\\Users\\<user>\\ws", "win32")).toBe(
      "C:/Users/<user>/ws",
    );
  });
});

describe("resolveDockerBindMountHostPath", () => {
  it("should resolve relative paths to absolute", () => {
    const resolved = resolveDockerBindMountHostPath("relative/workspace");
    expect(resolved).toMatch(RELATIVE_WORKSPACE_SUFFIX_REGEX);
  });
});
