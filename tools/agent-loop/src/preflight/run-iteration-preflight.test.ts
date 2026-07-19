import { describe, expect, it } from "vitest";

import { runIterationPreflight } from "./run-iteration-preflight.js";

describe("runIterationPreflight", () => {
  it("should no-op for CLIs without a checker", () => {
    expect(runIterationPreflight("claude", "any prompt").ok).toBe(true);
    expect(runIterationPreflight("codex", "any prompt").ok).toBe(true);
  });

  it("should delegate to the cursor checker", () => {
    expect(runIterationPreflight("cursor", "ok").ok).toBe(true);
  });
});
