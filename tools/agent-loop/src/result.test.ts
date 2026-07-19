import { describe, expect, it } from "vitest";

import { failure, matchResult, success, successVoid } from "./result.js";

describe("Result", () => {
  it("should branch with matchResult without throwing", () => {
    const ok = matchResult(
      success(42),
      (value) => `ok:${value}`,
      (error) => `fail:${error.exitCode}`,
    );
    expect(ok).toBe("ok:42");

    const bad = matchResult(
      failure(6, "too large"),
      () => "ok",
      (error) => `fail:${error.exitCode}`,
    );
    expect(bad).toBe("fail:6");
  });

  it("should represent void success", () => {
    expect(successVoid().ok).toBe(true);
  });
});
