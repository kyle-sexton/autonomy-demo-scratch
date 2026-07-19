import { describe, expect, it } from "vitest";

import { formatContainerProbeWarnings } from "./container-probe.js";

describe("formatContainerProbeWarnings", () => {
  it("should warn when jq is missing", () => {
    const warnings = formatContainerProbeWarnings({
      schemaVersion: 1,
      dependencies: [
        { name: "bash", present: true },
        { name: "git", present: true },
        { name: "jq", present: false },
      ],
      probeExitCode: 0,
    });
    expect(warnings.some((line) => line.includes("jq"))).toBe(true);
  });

  it("should warn when suppressed pool still has hooks key in settings", () => {
    const warnings = formatContainerProbeWarnings(
      {
        schemaVersion: 1,
        hookConfig: {
          hasCursorHooks: true,
          hasClaudeSettings: true,
          settingsHasHooksKey: true,
          cursorHooksFilePresent: true,
          cursorHooksEmpty: true,
        },
        probeExitCode: 0,
      },
      { inContainerHooks: "suppressed" },
    );
    expect(warnings.some((line) => line.includes("settings.json still has hooks key"))).toBe(true);
  });

  it("should warn when suppressed pool has non-empty cursor hooks file", () => {
    const warnings = formatContainerProbeWarnings(
      {
        schemaVersion: 1,
        hookConfig: {
          hasCursorHooks: true,
          hasClaudeSettings: true,
          settingsHasHooksKey: false,
          cursorHooksFilePresent: true,
          cursorHooksEmpty: false,
        },
        probeExitCode: 0,
      },
      { inContainerHooks: "suppressed" },
    );
    expect(warnings.some((line) => line.includes("non-empty"))).toBe(true);
  });
});
