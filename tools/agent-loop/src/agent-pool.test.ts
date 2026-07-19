import { describe, expect, it } from "vitest";

import { claudeAdapter } from "./adapters/claude.js";
import { codexAdapter } from "./adapters/codex.js";
import { cursorAdapter } from "./adapters/cursor.js";
import {
  CODEX_AGENT_POOL,
  resolveAgentPool,
  resolvePoolAdapter,
  resolvePoolAdditionalBindMounts,
} from "./agent-pool.js";

describe("resolvePoolAdapter", () => {
  it("should delegate to selectAdapter for each builtin CLI", () => {
    expect(resolvePoolAdapter({ cli: "cursor" })).toBe(cursorAdapter);
    expect(resolvePoolAdapter({ cli: "claude" })).toBe(claudeAdapter);
    expect(resolvePoolAdapter({ cli: "codex" })).toBe(codexAdapter);
  });
});

describe("resolvePoolAdditionalBindMounts", () => {
  it("should apply codex default credential mounts from the pool row", () => {
    const mounts = resolvePoolAdditionalBindMounts(CODEX_AGENT_POOL, "/repo", {});
    expect(mounts).toHaveLength(1);
    expect(mounts[0]?.readOnly).toBe(true);
    expect(mounts[0]?.containerPath).toBe("/var/codex-home/auth.json");
  });
});

describe("resolveAgentPool", () => {
  it("should resolve cursor pool by default", () => {
    const pool = resolveAgentPool(undefined, "/repo", {});
    expect(pool.id).toBe("cursor-default");
    expect(pool.cli).toBe("cursor");
    expect(pool.gateMarkerFilename).toContain("spend-safety-attestation-cursor.json");
  });
});
