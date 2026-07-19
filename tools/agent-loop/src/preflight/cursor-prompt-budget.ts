import type { Result } from "../result.js";
import { failure, successVoid } from "../result.js";

/** Cursor positional prompt argv budget (~120 KiB per runtime-reliability). */
export const CURSOR_PROMPT_ARGV_BUDGET_BYTES = 120 * 1024;

/** UTF-8 byte length of a prompt passed as a Cursor CLI positional argument. */
export function cursorPromptByteCount(prompt: string): number {
  return Buffer.byteLength(prompt, "utf8");
}

/**
 * Reject prompts that exceed the Cursor argv budget before any Docker spend.
 * Budget applies to prompt bytes only — fixed flags are negligible vs prompt body.
 */
export function validateCursorPromptByteBudget(prompt: string): Result<void> {
  const byteCount = cursorPromptByteCount(prompt);
  if (byteCount <= CURSOR_PROMPT_ARGV_BUDGET_BYTES) {
    return successVoid();
  }
  return failure(
    6,
    `prompt exceeds Cursor argv budget (${byteCount} bytes > ${CURSOR_PROMPT_ARGV_BUDGET_BYTES} bytes) — ` +
      "shorten the prompt file or split the slice before invoking the loop",
  );
}
