import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { loadSpendSafetyAttestation } from "./spend-safety-attestation.js";

describe("loadSpendSafetyAttestation", () => {
  it("should load the primary operator attestation path", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-attestation-"));
    mkdirSync(join(dir, "operator"), { recursive: true });
    const primary = join(dir, "operator/spend-safety-attestation-cursor.json");
    writeFileSync(
      primary,
      JSON.stringify({
        capHardStops: true,
        subscriptionBilled: true,
        pool: "cursor-default",
      }),
    );
    const marker = loadSpendSafetyAttestation(primary);
    expect(marker?.subscriptionBilled).toBe(true);
  });

  it("should return null when the operator attestation path is missing", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-attestation-missing-"));
    const primary = join(dir, "operator/spend-safety-attestation-cursor.json");
    expect(loadSpendSafetyAttestation(primary)).toBeNull();
  });
});
