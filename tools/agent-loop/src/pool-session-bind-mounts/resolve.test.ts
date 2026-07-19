import { describe, expect, it } from "vitest";

import { CLAUDE_AGENT_POOL, CODEX_AGENT_POOL, CURSOR_AGENT_POOL } from "../agent-pool.js";
import { resolvePoolSessionBindMounts } from "./resolve.js";

describe("resolvePoolSessionBindMounts", () => {
  it("should return empty mounts for claude and codex pools", () => {
    expect(
      resolvePoolSessionBindMounts(CLAUDE_AGENT_POOL, {
        workspaceRoot: "/ws",
        agentLoopProjectRoot: "/tool",
        runId: "test",
      }),
    ).toEqual([]);
    expect(
      resolvePoolSessionBindMounts(CODEX_AGENT_POOL, {
        workspaceRoot: "/ws",
        agentLoopProjectRoot: "/tool",
        runId: "test",
      }),
    ).toEqual([]);
  });

  it("should dispatch cursor pool to cursor resolver", () => {
    expect(CURSOR_AGENT_POOL.inContainerHooks).toBe("suppressed");
    expect(CURSOR_AGENT_POOL.cli).toBe("cursor");
  });
});
