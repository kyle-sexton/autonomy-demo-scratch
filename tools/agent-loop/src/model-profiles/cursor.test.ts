import { describe, expect, it } from "vitest";

import { CURSOR_DEFAULT_IMPLEMENT_MODEL, resolveCursorModelSlug } from "./cursor.js";
import { resolveModelSlug } from "./resolve.js";

describe("resolveCursorModelSlug", () => {
  it("should map implement roles", () => {
    expect(resolveCursorModelSlug({ role: "mechanical" })).toBe("composer-2.5-fast");
    expect(resolveCursorModelSlug({ role: "implement" })).toBe("composer-2.5-fast");
    expect(resolveCursorModelSlug({ role: "deep" })).toBe("claude-opus-4-8-thinking-xhigh");
  });

  it("should map effort tiers with and without thinking", () => {
    expect(resolveCursorModelSlug({ effort: "high" })).toBe("claude-opus-4-8-high");
    expect(resolveCursorModelSlug({ effort: "extra-high", thinking: true })).toBe(
      "claude-opus-4-8-thinking-xhigh",
    );
  });

  it("should default to CURSOR_DEFAULT_IMPLEMENT_MODEL", () => {
    expect(resolveCursorModelSlug({})).toBe(CURSOR_DEFAULT_IMPLEMENT_MODEL);
  });
});

describe("resolveModelSlug cursor overrides", () => {
  it("should prefer env override", () => {
    expect(resolveModelSlug("cursor", { role: "implement" }, "from-env")).toBe("from-env");
  });

  it("should prefer explicit model over role", () => {
    expect(resolveModelSlug("cursor", { model: "custom", role: "mechanical" })).toBe("custom");
  });
});
