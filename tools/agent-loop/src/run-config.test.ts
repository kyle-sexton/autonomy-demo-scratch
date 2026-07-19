import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { DEFAULT_OUTPUT_FORMAT } from "./constants.js";
import { CURSOR_DEFAULT_IMPLEMENT_MODEL } from "./model-profiles/cursor.js";
import {
  DEFAULT_MAX_ITERATIONS,
  loadRunLocalConfig,
  parseRunLocalConfig,
  RunLocalConfigError,
  resolveMaxIterations,
  resolveModelForTool,
  resolveOutputFormat,
} from "./run-config.js";

describe("loadRunLocalConfig", () => {
  it("should throw when run.local.json exists but is invalid", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-run-local-"));
    writeFileSync(join(dir, "run.local.json"), "{ not json");
    expect(() => loadRunLocalConfig(dir)).toThrow(RunLocalConfigError);
  });

  it("should return empty config when file is absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-run-local-missing-"));
    expect(loadRunLocalConfig(dir)).toEqual({});
  });
});

describe("run local config parse", () => {
  it("should parse profile fields and maxIterations", () => {
    expect(
      parseRunLocalConfig(
        '{"role":"implement","effort":"high","thinking":true,"maxIterations":10,"outputFormat":"text"}',
      ),
    ).toEqual({
      role: "implement",
      effort: "high",
      thinking: true,
      maxIterations: 10,
      outputFormat: "text",
    });
  });

  it("should ignore invalid role and effort", () => {
    expect(parseRunLocalConfig('{"role":"nope","effort":"max"}')).toEqual({});
  });
});

describe("resolveModelForTool", () => {
  it("should map role via cursor adapter table", () => {
    expect(resolveModelForTool("cursor", { role: "mechanical" })).toBe("composer-2.5-fast");
  });

  it("should fall back to default implement model", () => {
    expect(resolveModelForTool("cursor", {})).toBe(CURSOR_DEFAULT_IMPLEMENT_MODEL);
  });
});

describe("resolveMaxIterations", () => {
  it("should prefer CLI over env file and default", () => {
    expect(resolveMaxIterations({ maxIterations: 3 }, 8, "5")).toBe(8);
  });

  it("should use env when CLI omitted", () => {
    expect(resolveMaxIterations({ maxIterations: 3 }, undefined, "5")).toBe(5);
  });

  it("should use run.local.json when CLI and env omitted", () => {
    expect(resolveMaxIterations({ maxIterations: 4 })).toBe(4);
  });

  it("should fall back to DEFAULT_MAX_ITERATIONS", () => {
    expect(resolveMaxIterations({})).toBe(DEFAULT_MAX_ITERATIONS);
  });
});

describe("resolveOutputFormat", () => {
  it("should default to stream-json when run.local.json omits outputFormat", () => {
    expect(resolveOutputFormat({})).toBe(DEFAULT_OUTPUT_FORMAT);
    expect(resolveOutputFormat({})).toBe("stream-json");
  });

  it("should honor explicit outputFormat in run.local.json", () => {
    expect(resolveOutputFormat({ outputFormat: "text" })).toBe("text");
  });
});
