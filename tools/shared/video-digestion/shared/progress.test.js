import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createTracker } from "./progress.js";

function getStdoutCalls() {
  return process.stdout.write.mock.calls.map(([chunk]) => String(chunk));
}

describe("createTracker", () => {
  beforeEach(() => {
    vi.spyOn(process.stdout, "write").mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("should create a tracker with correct total", () => {
    const tracker = createTracker(45);
    expect(tracker).toBeDefined();
    expect(typeof tracker.start).toBe("function");
    expect(typeof tracker.item).toBe("function");
    expect(typeof tracker.finish).toBe("function");
    expect(typeof tracker.report).toBe("function");
  });

  it("should log progress line on item()", () => {
    const tracker = createTracker(10);
    tracker.start();
    tracker.item(1, "Welcome", { success: true, chars: 1234, durationMs: 4200 });

    expect(process.stdout.write).toHaveBeenCalled();
    const output = getStdoutCalls().find((line) => line.includes("[1/10]"));
    expect(output).toBeDefined();
    expect(output).toContain("Welcome");
    expect(output).toContain("OK");
  });

  it("should show FAIL for unsuccessful items", () => {
    const tracker = createTracker(5);
    tracker.start();
    tracker.item(1, "Broken Lesson", { success: false, error: "timeout", durationMs: 1500 });

    const output = getStdoutCalls().find((line) => line.includes("[1/5]"));
    expect(output).toContain("FAIL");
  });

  it("should include elapsed time in progress line", () => {
    const tracker = createTracker(3);
    tracker.start();
    tracker.item(1, "Lesson 1", { success: true, durationMs: 100 });

    const output = getStdoutCalls().find((line) => line.includes("[1/3]"));
    expect(output).toContain("Elapsed:");
  });

  it("should produce a valid report", () => {
    const tracker = createTracker(2);
    tracker.start();
    tracker.item(1, "L1", { success: true, chars: 500, durationMs: 3000 });
    tracker.item(2, "L2", { success: false, error: "nav error", durationMs: 1000 });
    const report = tracker.finish();

    expect(report.totalItems).toBe(2);
    expect(report.succeeded).toBe(1);
    expect(report.failed).toBe(1);
    expect(report.items).toHaveLength(2);
    expect(report.items[0].status).toBe("success");
    expect(report.items[1].status).toBe("failed");
    expect(report.totalDurationMs).toBeGreaterThanOrEqual(0);
  });

  it("report() returns same data as finish()", () => {
    const tracker = createTracker(1);
    tracker.start();
    tracker.item(1, "L1", { success: true, durationMs: 100 });
    tracker.finish();
    const report = tracker.report();

    expect(report.totalItems).toBe(1);
    expect(report.items).toHaveLength(1);
  });
});
