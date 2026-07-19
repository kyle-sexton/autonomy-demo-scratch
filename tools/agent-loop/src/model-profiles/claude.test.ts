import { describe, expect, it } from "vitest";

import { resolveClaudeModelSlug } from "./claude.js";
import { resolveModelSlug } from "./resolve.js";

describe("resolveClaudeModelSlug", () => {
  it("should map roles when explicit model omitted", () => {
    expect(resolveClaudeModelSlug({ role: "mechanical" })).toBe("claude-haiku-4-5");
    expect(resolveClaudeModelSlug({ role: "implement" })).toBe("claude-sonnet-4-6");
    expect(resolveClaudeModelSlug({ role: "deep" })).toBe("claude-opus-4-8");
  });

  it("should map effort tiers", () => {
    expect(resolveClaudeModelSlug({ effort: "low" })).toBe("claude-sonnet-4-6");
    expect(resolveClaudeModelSlug({ effort: "medium" })).toBe("claude-sonnet-4-6");
    expect(resolveClaudeModelSlug({ effort: "high" })).toBe("claude-opus-4-8");
    expect(resolveClaudeModelSlug({ effort: "extra-high" })).toBe("claude-opus-4-8");
  });

  it("should default to implement role model", () => {
    expect(resolveClaudeModelSlug({})).toBe("claude-sonnet-4-6");
  });

  it("should honor explicit model via resolveModelSlug", () => {
    expect(resolveModelSlug("claude", { model: "claude-sonnet-4" })).toBe("claude-sonnet-4");
  });
});
