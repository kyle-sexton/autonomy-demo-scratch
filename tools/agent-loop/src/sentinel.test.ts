import { describe, expect, it } from "vitest";

import { parseSentinel } from "./sentinel.js";

// Build fixtures from short fragments so no single high-entropy literal trips the
// noSecrets lint — the assembled runtime string is the real promise token.
const OPEN = "<promise>";
const CLOSE = "</promise>";
const tag = (value: string): string => `${OPEN}${value}${CLOSE}`;

describe("parseSentinel", () => {
  it("should return null when no promise token is present", () => {
    expect(parseSentinel("some log output\nno token here")).toBeNull();
  });

  it("should parse a single CONTINUE token", () => {
    expect(parseSentinel(tag("CONTINUE"))).toBe("CONTINUE");
  });

  it("should parse a single NO_MORE_TASKS token", () => {
    expect(parseSentinel(tag("NO_MORE_TASKS"))).toBe("NO_MORE_TASKS");
  });

  it("should return the last token when multiple are present (loop.sh tail -1 model)", () => {
    const log = `${tag("CONTINUE")}\n...more...\n${tag("NO_MORE_TASKS")}`;
    expect(parseSentinel(log)).toBe("NO_MORE_TASKS");
  });

  it("should find a token embedded in surrounding prose on the final line", () => {
    const log = `I created out/1.txt.\nDone. ${tag("CONTINUE")}`;
    expect(parseSentinel(log)).toBe("CONTINUE");
  });

  it("should ignore an unknown promise value", () => {
    expect(parseSentinel(tag("MAYBE"))).toBeNull();
  });

  it("should ignore a malformed token missing its closing tag", () => {
    expect(parseSentinel(`${OPEN}CONTINUE`)).toBeNull();
  });
});
