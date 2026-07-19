import { describe, expect, it } from "vitest";

import {
  CURSOR_PROMPT_ARGV_BUDGET_BYTES,
  cursorPromptByteCount,
  validateCursorPromptByteBudget,
} from "./cursor-prompt-budget.js";

describe("cursorPromptByteCount", () => {
  it("should count UTF-8 bytes", () => {
    expect(cursorPromptByteCount("abc")).toBe(3);
    expect(cursorPromptByteCount("é")).toBe(2);
  });
});

describe("validateCursorPromptByteBudget", () => {
  it("should pass when under budget", () => {
    expect(validateCursorPromptByteBudget("short prompt").ok).toBe(true);
  });

  it("should fail with exit 6 when over budget", () => {
    const prompt = "x".repeat(CURSOR_PROMPT_ARGV_BUDGET_BYTES + 1);
    const result = validateCursorPromptByteBudget(prompt);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.exitCode).toBe(6);
      expect(result.error.message).toContain(String(CURSOR_PROMPT_ARGV_BUDGET_BYTES));
    }
  });
});
