import { describe, expect, it } from "vitest";

import { parseFfprobeDuration } from "./ffprobe-duration.js";

describe("parseFfprobeDuration", () => {
  it("parses format duration", () => {
    const result = parseFfprobeDuration(
      JSON.stringify({ format: { duration: "123.456", format_name: "mov,mp4,m4a,3gp,3g2,mj2" } }),
    );
    expect(result?.durationSec).toBeCloseTo(123.456);
  });
});
