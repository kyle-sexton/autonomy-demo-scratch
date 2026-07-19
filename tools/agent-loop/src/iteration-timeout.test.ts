import { describe, expect, it } from "vitest";

import { evaluateIterationTimeout, type IterationTimeoutConfig } from "./iteration-timeout.js";

const config: IterationTimeoutConfig = {
  idleTimeoutMs: 10_000,
  maxWallClockMs: 60_000,
  completionGraceMs: 1_000,
};

describe("evaluateIterationTimeout", () => {
  it("should not kill while idle timer has not elapsed and no sentinel", () => {
    const result = evaluateIterationTimeout({
      elapsedMs: 5_000,
      msSinceLastOutput: 5_000,
      msSinceSentinel: null,
      config,
    });
    expect(result.shouldKill).toBe(false);
    expect(result.inCompletionGrace).toBe(false);
  });

  it("should kill on idle timeout when no sentinel has appeared", () => {
    const result = evaluateIterationTimeout({
      elapsedMs: 12_000,
      msSinceLastOutput: 10_000,
      msSinceSentinel: null,
      config,
    });
    expect(result).toEqual({
      shouldKill: true,
      reason: "idle",
      inCompletionGrace: false,
    });
  });

  it("should reset idle evaluation via msSinceLastOutput without requiring code state", () => {
    const result = evaluateIterationTimeout({
      elapsedMs: 12_000,
      msSinceLastOutput: 2_000,
      msSinceSentinel: null,
      config,
    });
    expect(result.shouldKill).toBe(false);
  });

  it("should enter completion grace after sentinel and kill when grace expires", () => {
    const beforeGrace = evaluateIterationTimeout({
      elapsedMs: 20_500,
      msSinceLastOutput: 500,
      msSinceSentinel: 500,
      config,
    });
    expect(beforeGrace.shouldKill).toBe(false);
    expect(beforeGrace.inCompletionGrace).toBe(true);

    const afterGrace = evaluateIterationTimeout({
      elapsedMs: 21_000,
      msSinceLastOutput: 1_000,
      msSinceSentinel: 1_000,
      config,
    });
    expect(afterGrace).toEqual({
      shouldKill: true,
      reason: "completion-grace",
      inCompletionGrace: true,
    });
  });

  it("should kill on max wall clock backstop even during completion grace", () => {
    const result = evaluateIterationTimeout({
      elapsedMs: config.maxWallClockMs,
      msSinceLastOutput: 1_000,
      msSinceSentinel: 10_000,
      config,
    });
    expect(result).toEqual({
      shouldKill: true,
      reason: "wall-clock",
      inCompletionGrace: true,
    });
  });
});
