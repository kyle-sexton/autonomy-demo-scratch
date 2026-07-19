import { describe, expect, it } from "vitest";

import {
  analyzeHookFailuresFromToolCallsContent,
  buildIterationHookReport,
  classifyHookBlockMessage,
  formatHookFailuresMarkdown,
  formatHookObservabilityLog,
  recommendationForHookFailure,
} from "./hook-observability.js";

describe("classifyHookBlockMessage", () => {
  it("should classify JSON passed to bash as launcher_transport", () => {
    const message = [
      "Hook blocked write: bash: line 1: syntax error near unexpected token",
      '{"conversation_id":"abc","tool_input":{}}',
    ].join("\n");
    expect(classifyHookBlockMessage(message)).toBe("launcher_transport");
  });

  it("should classify jq missing as missing_dependency", () => {
    expect(classifyHookBlockMessage("jq: command not found")).toBe("missing_dependency");
  });

  it("should classify hardcoded path feedback as policy_block", () => {
    expect(classifyHookBlockMessage("Hook blocked: hardcoded machine-specific path detected")).toBe(
      "policy_block",
    );
  });

  it("should classify hardcoded path before conversation_id heuristics", () => {
    const message = [
      "Hook blocked with message: Hardcoded machine-specific path(s) in /workspace/foo.md",
      '{"conversation_id":"abc"}',
    ].join("\n");
    expect(classifyHookBlockMessage(message)).toBe("policy_block");
  });

  it("should use suppression recommendation when inContainerHooks is suppressed", () => {
    const recommendation = recommendationForHookFailure("launcher_transport", "suppressed");
    expect(recommendation).toContain("suppressed");
  });

  it("should classify markdown path executed as shell as launcher_transport", () => {
    expect(
      classifyHookBlockMessage("Hook blocked write: teachable.md: No such file or directory"),
    ).toBe("launcher_transport");
  });
});

describe("analyzeHookFailuresFromToolCallsContent", () => {
  it("should extract classified hook failures from tool-calls jsonl", () => {
    const line = JSON.stringify({
      type: "tool_call",
      tool_call: {
        editToolCall: {
          args: { path: "/workspace/foo.md" },
          result: {
            error: {
              error: 'Hook blocked write: bash: syntax error\n{"conversation_id":"x"}',
            },
          },
        },
      },
    });
    const failures = analyzeHookFailuresFromToolCallsContent(line);
    expect(failures).toHaveLength(1);
    expect(failures[0]?.kind).toBe("launcher_transport");
    expect(failures[0]?.filePath).toBe("/workspace/foo.md");
    expect(failures[0]?.recommendation).toContain("launcher");
  });
});

describe("hook observability log formatting", () => {
  it("should return empty string when no failures", () => {
    const report = buildIterationHookReport(1, "iteration-01-cursor", []);
    expect(formatHookObservabilityLog(report)).toBe("");
  });

  it("should format failures with kind and recommendation", () => {
    const failures = analyzeHookFailuresFromToolCallsContent(
      JSON.stringify({
        type: "tool_call",
        tool_call: {
          editToolCall: {
            result: { error: { error: "jq: command not found" } },
          },
        },
      }),
    );
    const report = buildIterationHookReport(1, "iteration-01-cursor", failures);
    const log = formatHookObservabilityLog(report);
    expect(log).toContain("missing_dependency");
    expect(log).toContain("jq");
  });
});

describe("formatHookFailuresMarkdown", () => {
  it("should return sentinel when no hook blocks detected", () => {
    expect(formatHookFailuresMarkdown([])).toBe("_no hook blocks detected in tool-calls sidecars_");
  });

  it("should render failures with optional file path and recommendations", () => {
    const failures = analyzeHookFailuresFromToolCallsContent(
      JSON.stringify({
        type: "tool_call",
        tool_call: {
          editToolCall: {
            args: { path: "/workspace/foo.md" },
            result: { error: { error: "jq: command not found" } },
          },
        },
      }),
    );
    const report = buildIterationHookReport(2, "iteration-02-cursor", failures);
    const markdown = formatHookFailuresMarkdown([report]);
    expect(markdown).toContain("### Iteration 2");
    expect(markdown).toContain("missing_dependency");
    expect(markdown).toContain("`/workspace/foo.md`");
    expect(markdown).toContain("action:");
  });
});
