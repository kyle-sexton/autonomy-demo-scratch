import { describe, expect, it } from "vitest";

import { CURSOR_AGENT_POOL } from "./agent-pool.js";
import { defaultCliExtensionStrategies } from "./cli-extensions.js";
import { streamJsonOutputParser } from "./output-parsers/stream-json-parser.js";

describe("defaultCliExtensionStrategies", () => {
  it("should wire production registries together", () => {
    const { strategies } = { strategies: defaultCliExtensionStrategies };
    expect(strategies.resolvePoolAdapter(CURSOR_AGENT_POOL)).toBe(
      strategies.selectAdapter("cursor"),
    );
    expect(strategies.selectOutputParser("cursor", "stream-json")).toBe(streamJsonOutputParser);
    expect(strategies.runIterationPreflight("claude", "prompt").ok).toBe(true);
    expect(strategies.resolveModelSlug("cursor", { role: "mechanical" })).toBe("composer-2.5-fast");
  });
});
