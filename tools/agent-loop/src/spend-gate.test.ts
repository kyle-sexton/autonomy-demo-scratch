import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { CURSOR_AGENT_POOL } from "./agent-pool.js";
import { PoolsLocalConfigError } from "./pools-config.js";
import { evaluateSpendGateOrError, loadPoolsConfigForSpendGate } from "./spend-gate.js";

describe("loadPoolsConfigForSpendGate", () => {
  it("should propagate invalid pools.local.jsonc parse errors", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-spend-gate-pools-"));
    writeFileSync(join(dir, "pools.local.jsonc"), "{ invalid");
    expect(() => loadPoolsConfigForSpendGate(dir)).toThrow(PoolsLocalConfigError);
  });
});

describe("evaluateSpendGateOrError", () => {
  it("should refuse when attestation is absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-spend-gate-"));
    const result = evaluateSpendGateOrError(CURSOR_AGENT_POOL, dir, {});
    expect(result).toBeDefined();
    expect(result?.exitCode).toBe(1);
    expect(result?.message).toContain("marker absent");
  });

  it("should allow when attestation is valid", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-spend-gate-ok-"));
    mkdirSync(join(dir, "operator"), { recursive: true });
    writeFileSync(
      join(dir, CURSOR_AGENT_POOL.gateMarkerFilename),
      JSON.stringify({
        capHardStops: true,
        subscriptionBilled: true,
        pool: CURSOR_AGENT_POOL.gatePoolId,
      }),
    );
    expect(evaluateSpendGateOrError(CURSOR_AGENT_POOL, dir, {})).toBeUndefined();
  });
});
