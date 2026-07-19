import { describe, expect, it } from "vitest";

import { scanCodexJsonOutput } from "./codex-json.js";

describe("scanCodexJsonOutput", () => {
  it("should prefer terminal result field", () => {
    const output = [
      '{"type":"item","item":{"type":"agent_message","text":"partial"}}',
      '{"type":"result","result":"<promise>NO_MORE_TASKS</promise>"}',
    ].join("\n");
    expect(scanCodexJsonOutput(output).text).toBe("<promise>NO_MORE_TASKS</promise>");
  });

  it("should concatenate item text when no result event", () => {
    const output = '{"item":{"text":"hello sentinel"}}';
    expect(scanCodexJsonOutput(output).text).toContain("hello sentinel");
  });

  it("should ignore non-json lines", () => {
    expect(scanCodexJsonOutput('not json\n{"message":"ok"}').text).toBe("ok");
  });
});
