import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  formatIterationLabel,
  iterationAgentOutputLogPath,
  iterationMetaPath,
  iterationToolCallsPath,
  ORCHESTRATOR_LOG_FILENAME,
} from "./iteration-artifacts.js";

describe("iteration artifact paths", () => {
  it("should use zero-padded iteration labels", () => {
    expect(formatIterationLabel(1, "cursor")).toBe("iteration-01-cursor");
    expect(formatIterationLabel(12, "claude")).toBe("iteration-12-claude");
  });

  it("should name agent-output, meta, and tool-call files from the label", () => {
    const label = formatIterationLabel(1, "cursor");
    const dir = "/tool/logs/runs/run-abc";
    expect(iterationAgentOutputLogPath(dir, label)).toBe(join(dir, `${label}-agent-output.log`));
    expect(iterationMetaPath(dir, label)).toBe(join(dir, `${label}-meta.json`));
    expect(iterationToolCallsPath(dir, label)).toBe(join(dir, `${label}-tool-calls.jsonl`));
  });

  it("should use orchestrator.log for the run summary file", () => {
    expect(ORCHESTRATOR_LOG_FILENAME).toBe("orchestrator.log");
  });
});
