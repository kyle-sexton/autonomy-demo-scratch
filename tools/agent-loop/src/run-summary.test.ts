import { describe, expect, it } from "vitest";

import { buildRunSummaryMarkdown, digestToolCallsJsonl } from "./run-summary.js";

describe("digestToolCallsJsonl", () => {
  it("should extract shell commands and hook errors", () => {
    const line = JSON.stringify({
      type: "tool_call",
      tool_call: {
        shellToolCall: { args: { command: "git status --short" } },
      },
    });
    const errLine = JSON.stringify({
      type: "tool_call",
      tool_call: {
        editToolCall: { result: { error: { error: "Hook blocked write" } } },
      },
    });
    const digest = digestToolCallsJsonl(`${line}\n${errLine}`);
    expect(digest.some((d) => d.kind === "shell")).toBe(true);
    expect(digest.some((d) => d.kind === "hook-block")).toBe(true);
  });
});

describe("buildRunSummaryMarkdown", () => {
  it("should include outcome and token sections", () => {
    const md = buildRunSummaryMarkdown({
      runId: "test-run",
      logsDirectory: "/logs/test",
      decision: { decision: "done", mismatch: false, reason: "ok" },
      finalExitCode: 0,
      gateResult: {
        fsComplete: true,
        progressed: true,
        beforeCount: 0,
        afterCount: 1,
        blockedPresent: false,
        selfCheckPresent: true,
        completionFilePresent: true,
        reason: "files present",
      },
      gitBefore: { statusShort: "", diffStat: "", untrackedAtRoot: [] },
      gitAfter: { statusShort: "", diffStat: "", untrackedAtRoot: [] },
      gitDiff: { newUntrackedAtRoot: [], newRootJunk: [] },
      iterations: [{ iteration: 1, elapsedMs: 100, sentinel: "NO_MORE_TASKS", exitCode: 0 }],
      usage: { inputTokens: 10, outputTokens: 5 },
      completionFile: "out/phase-1.done",
    });
    expect(md).toContain("## Tokens");
    expect(md).toContain("input=10");
    expect(md).toContain("test-run");
  });
});
