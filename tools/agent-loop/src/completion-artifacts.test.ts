import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { countCompletionArtifacts } from "./completion-artifacts.js";

describe("countCompletionArtifacts", () => {
  it("should count regular files and ignore dotfiles and subdirs", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-artifacts-"));
    try {
      writeFileSync(join(dir, "a.md"), "x");
      writeFileSync(join(dir, "b.txt"), "x");
      writeFileSync(join(dir, ".hidden"), "x");
      expect(countCompletionArtifacts(dir)).toBe(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("should return 0 when directory is missing", () => {
    expect(countCompletionArtifacts("/nonexistent/path/agent-loop-test")).toBe(0);
  });
});
