import { describe, expect, it } from "vitest";

import { resolveCodexModelSlug } from "./codex.js";
import { resolveModelSlug } from "./resolve.js";

describe("resolveCodexModelSlug", () => {
  it("should map roles", () => {
    expect(resolveCodexModelSlug({ role: "mechanical" })).toBe("gpt-5.3-codex-spark");
    expect(resolveCodexModelSlug({ role: "implement" })).toBe("gpt-5.3-codex");
    expect(resolveCodexModelSlug({ role: "deep" })).toBe("gpt-5.3-codex-high");
  });

  it("should map effort tiers", () => {
    expect(resolveCodexModelSlug({ effort: "low" })).toBe("gpt-5.3-codex-spark");
    expect(resolveCodexModelSlug({ effort: "medium" })).toBe("gpt-5.3-codex");
    expect(resolveCodexModelSlug({ effort: "high" })).toBe("gpt-5.3-codex-high");
    expect(resolveCodexModelSlug({ effort: "extra-high" })).toBe("gpt-5.3-codex-high");
  });

  it("should default to implement role model", () => {
    expect(resolveCodexModelSlug({})).toBe("gpt-5.3-codex");
  });

  it("should honor explicit model via resolveModelSlug", () => {
    expect(resolveModelSlug("codex", { model: "custom-codex" })).toBe("custom-codex");
  });
});
