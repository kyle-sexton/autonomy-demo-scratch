import { describe, expect, it } from "vitest";

import { createSentinelStreamDetector } from "./sentinel-stream-detector.js";

describe("createSentinelStreamDetector", () => {
  it("should ignore promise prose in stream-json user echo until result event", () => {
    const detector = createSentinelStreamDetector("stream-json");
    const promptEcho = [
      '{"type":"user","message":"Emit CONTINUE promise token when work remains."}',
      '{"type":"assistant","message":"working"}',
    ].join("\n");
    expect(detector.scan(promptEcho)).toBe(false);
  });

  it("should detect sentinel in stream-json terminal result event", () => {
    const detector = createSentinelStreamDetector("stream-json");
    const output = [
      '{"type":"user","message":"mention CONTINUE in prose"}',
      '{"type":"result","result":"done\\n<promise>NO_MORE_TASKS</promise>"}',
    ].join("\n");
    expect(detector.scan(output)).toBe(true);
  });

  it("should scan full log for plain text output", () => {
    const detector = createSentinelStreamDetector("text");
    expect(detector.scan("work\n<promise>CONTINUE</promise>")).toBe(true);
    expect(detector.scan('{"type":"user","message":"<promise>CONTINUE</promise>"}')).toBe(true);
  });
});
