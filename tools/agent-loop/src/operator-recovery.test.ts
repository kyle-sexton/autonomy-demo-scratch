import { describe, expect, it } from "vitest";

import { buildFailureRecoveryGuide, modelOverrideEnvVarName } from "./operator-recovery.js";

describe("buildFailureRecoveryGuide", () => {
  it("should map mechanical role per CLI without orchestrator knowing vendor slugs", () => {
    expect(
      buildFailureRecoveryGuide("cursor", "claude-opus-4-8-xhigh").mechanicalRoleModelSlug,
    ).toBe("composer-2.5-fast");
    expect(buildFailureRecoveryGuide("claude", "claude-opus-4-6").mechanicalRoleModelSlug).toBe(
      "claude-haiku-4-5",
    );
    expect(buildFailureRecoveryGuide("codex", "gpt-5.3-codex-high").mechanicalRoleModelSlug).toBe(
      "gpt-5.3-codex-spark",
    );
  });

  it("should preserve the model slug used on the failed iteration", () => {
    const guide = buildFailureRecoveryGuide("cursor", "test-model");
    expect(guide.modelUsed).toBe("test-model");
    expect(guide.agentCli).toBe("cursor");
  });
});

describe("modelOverrideEnvVarName", () => {
  it("should expose the canonical AGENT_LOOP_MODEL name", () => {
    expect(modelOverrideEnvVarName()).toBe("AGENT_LOOP_MODEL");
  });
});
