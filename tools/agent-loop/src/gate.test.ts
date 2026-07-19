import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { evaluateGateForPool, loadGateMarkerFromFile } from "./gate.js";

describe("loadGateMarkerFromFile", () => {
  it("should distinguish absent from invalid JSON", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-gate-"));
    const path = join(dir, "attestation.json");
    expect(loadGateMarkerFromFile(path)).toEqual({ status: "absent" });

    writeFileSync(path, "{ not-json");
    const invalid = loadGateMarkerFromFile(path);
    expect(invalid.status).toBe("invalid");
    if (invalid.status === "invalid") {
      expect(invalid.detail).toContain("JSON parse failed");
    }
  });
});

describe("evaluateGateForPool", () => {
  it("should REFUSE when the marker is absent", () => {
    const decision = evaluateGateForPool(
      { status: "absent" },
      {
        poolId: "claude-default",
        markerLabel: "Claude spend-safety attestation",
      },
    );
    expect(decision.allowed).toBe(false);
    if (!decision.allowed) {
      expect(decision.reason).toContain("marker absent");
    }
  });

  it("should REFUSE when marker JSON is invalid", () => {
    const decision = evaluateGateForPool(
      { status: "invalid", detail: "JSON parse failed: Unexpected token" },
      {
        poolId: "claude-default",
        markerLabel: "Claude spend-safety attestation",
      },
    );
    expect(decision.allowed).toBe(false);
    if (!decision.allowed) {
      expect(decision.reason).toContain("marker invalid");
      expect(decision.reason).not.toContain("marker absent");
    }
  });

  it("should REFUSE when marker pool does not match selected pool", () => {
    const decision = evaluateGateForPool(
      {
        status: "ok",
        marker: { capHardStops: true, subscriptionBilled: true, pool: "cursor-default" },
      },
      { poolId: "claude-default", markerLabel: "Claude spend-safety attestation" },
    );
    expect(decision.allowed).toBe(false);
    if (!decision.allowed) {
      expect(decision.reason).toContain("does not match");
    }
  });

  it("should ALLOW when both halves are confirmed for the pool", () => {
    const decision = evaluateGateForPool(
      {
        status: "ok",
        marker: { capHardStops: true, subscriptionBilled: true, pool: "codex-default" },
      },
      { poolId: "codex-default", markerLabel: "Codex spend-safety attestation" },
    );
    expect(decision.allowed).toBe(true);
  });
});
