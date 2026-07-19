import { describe, expect, it } from "vitest";

import { decideCompletion } from "./completion.js";

describe("decideCompletion", () => {
  it("should be DONE when sentinel is NO_MORE_TASKS and fs is complete (both signals agree)", () => {
    const r = decideCompletion({ sentinel: "NO_MORE_TASKS", fsComplete: true, progressed: false });
    expect(r.decision).toBe("done");
    expect(r.mismatch).toBe(false);
  });

  // LOAD-BEARING (Brief acceptance #2): the false-completion guard. A lying
  // sentinel must never end the loop while the backlog is incomplete.
  it("should be STUCK, never DONE, when sentinel claims NO_MORE_TASKS but fs is incomplete", () => {
    const r = decideCompletion({ sentinel: "NO_MORE_TASKS", fsComplete: false, progressed: false });
    expect(r.decision).toBe("stuck");
    expect(r.decision).not.toBe("done");
  });

  it("should still be STUCK when sentinel is NO_MORE_TASKS and fs incomplete even if this iteration progressed", () => {
    const r = decideCompletion({ sentinel: "NO_MORE_TASKS", fsComplete: false, progressed: true });
    expect(r.decision).toBe("stuck");
  });

  it("should be DONE with a mismatch flag when fs is complete but sentinel says CONTINUE (fs is ground truth)", () => {
    const r = decideCompletion({ sentinel: "CONTINUE", fsComplete: true, progressed: true });
    expect(r.decision).toBe("done");
    expect(r.mismatch).toBe(true);
  });

  it("should CONTINUE when sentinel is CONTINUE, fs incomplete, and progress was made", () => {
    const r = decideCompletion({ sentinel: "CONTINUE", fsComplete: false, progressed: true });
    expect(r.decision).toBe("continue");
    expect(r.mismatch).toBe(false);
  });

  it("should be STUCK when sentinel is CONTINUE, fs incomplete, and no progress was made", () => {
    const r = decideCompletion({ sentinel: "CONTINUE", fsComplete: false, progressed: false });
    expect(r.decision).toBe("stuck");
  });

  it("should be DONE with a mismatch flag when there is no sentinel but fs is complete", () => {
    const r = decideCompletion({ sentinel: null, fsComplete: true, progressed: true });
    expect(r.decision).toBe("done");
    expect(r.mismatch).toBe(true);
  });

  it("should CONTINUE when there is no sentinel, fs incomplete, but progress was made", () => {
    const r = decideCompletion({ sentinel: null, fsComplete: false, progressed: true });
    expect(r.decision).toBe("continue");
  });

  it("should be STUCK when there is no sentinel, fs incomplete, and no progress", () => {
    const r = decideCompletion({ sentinel: null, fsComplete: false, progressed: false });
    expect(r.decision).toBe("stuck");
  });

  it("should be FAILED when agentFailed even if sentinel would parse as NO_MORE_TASKS", () => {
    const r = decideCompletion({
      sentinel: "NO_MORE_TASKS",
      fsComplete: false,
      progressed: false,
      agentFailed: true,
      agentExitCode: 1,
    });
    expect(r.decision).toBe("failed");
    expect(r.reason).toContain("exited 1");
  });

  it("should always include a non-empty reason for observability", () => {
    const r = decideCompletion({ sentinel: "NO_MORE_TASKS", fsComplete: false, progressed: false });
    expect(r.reason.length).toBeGreaterThan(0);
  });
});
