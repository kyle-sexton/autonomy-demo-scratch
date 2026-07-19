import { describe, expect, it } from "vitest";

const EXCESSIVE_NEWLINES_PATTERN = /\n{4,}/u;
const BANNER_ITERATION_LAYOUT_PATTERN = /orchestrator log:.*\n─{10,}\n\n─{10,}/su;

import {
  formatAgentFailureOperatorGuidance,
  formatAgentOutputBlock,
  formatIterationStart,
  formatRunBanner,
} from "./run-console.js";

describe("formatRunBanner", () => {
  it("should use a single blank line before the first iteration section", () => {
    const banner = formatRunBanner({
      runId: "run-1",
      tool: "cursor",
      workspacePath: "/ws/demo",
      workspaceSlug: "demo",
      promptPath: "/ws/prompt.txt",
      target: 1,
      outSubdir: "out",
      cap: 4,
      runLogPath: "/ws/logs/run-1.log",
    });
    const iteration = formatIterationStart({
      iteration: 1,
      cap: 4,
      containerName: "agent-loop-cursor-demo-i1",
    });
    const combined = `${banner}${iteration}`;
    expect(combined).not.toMatch(EXCESSIVE_NEWLINES_PATTERN);
    expect(combined).toMatch(BANNER_ITERATION_LAYOUT_PATTERN);
  });

  it("should include run id, tool, workspace, and completion target", () => {
    const text = formatRunBanner({
      runId: "run-1",
      tool: "cursor",
      workspacePath: "/ws/demo",
      workspaceSlug: "demo",
      promptPath: "/ws/prompt.txt",
      target: 2,
      outSubdir: "out",
      cap: 4,
      runLogPath: "/ws/logs/run-1.log",
    });
    expect(text).toContain("run id:        run-1");
    expect(text).toContain("tool:          cursor");
    expect(text).toContain("workspace:     /ws/demo");
    expect(text).toContain("2 file(s) in out/");
  });
});

describe("formatAgentFailureOperatorGuidance", () => {
  it("should stay tool-agnostic and reference mechanical role without implying auto-retry", () => {
    const text = formatAgentFailureOperatorGuidance({
      iteration: 2,
      exitCode: 1,
      iterLogPath: "logs/runs/x/iteration-02-cursor-agent-output.log",
      guide: {
        agentCli: "cursor",
        modelUsed: "claude-4.6-opus-high-thinking",
        mechanicalRoleModelSlug: "composer-2.5-fast",
      },
    });
    expect(text).toContain("no auto-continue");
    expect(text).toContain("iteration-02-cursor-agent-output.log");
    expect(text).toContain("tool:          cursor");
    expect(text).toContain('role "mechanical" → composer-2.5-fast');
    expect(text).toContain("AGENT_LOOP_MODEL");
    expect(text).not.toContain("Cursor frontier");
  });
});

describe("agentOutputBlock", () => {
  it("should wrap agent text in rule lines", () => {
    const open = "<promise>";
    const close = "</promise>";
    const token = `${open}CONTINUE${close}`;
    const text = formatAgentOutputBlock(1, `hello\n${token}`, "logs/i1.log");
    expect(text).toContain("iteration 1");
    expect(text).toContain("hello");
    expect(text).toContain(token);
  });
});
