import { describe, expect, it } from "vitest";

import { resolveGrokModelSlug } from "./grok.js";
import { resolveModelSlug } from "./resolve.js";

describe("resolveGrokModelSlug", () => {
  it("should map roles", () => {
    expect(resolveGrokModelSlug({ role: "mechanical" })).toBe("grok-build");
    expect(resolveGrokModelSlug({ role: "implement" })).toBe("composer-2.5");
    expect(resolveGrokModelSlug({ role: "deep" })).toBe("composer-2.5");
  });

  it("should map effort tiers", () => {
    expect(resolveGrokModelSlug({ effort: "low" })).toBe("grok-build");
    expect(resolveGrokModelSlug({ effort: "medium" })).toBe("composer-2.5");
    expect(resolveGrokModelSlug({ effort: "high" })).toBe("composer-2.5");
    expect(resolveGrokModelSlug({ effort: "extra-high" })).toBe("composer-2.5");
  });

  it("should default to implement role model", () => {
    expect(resolveGrokModelSlug({})).toBe("composer-2.5");
  });

  it("should honor explicit model via resolveModelSlug", () => {
    expect(resolveModelSlug("grok", { model: "custom-grok" })).toBe("custom-grok");
  });
});
