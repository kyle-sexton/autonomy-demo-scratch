import { existsSync, readFileSync } from "node:fs";

import type { GateDecision, GateMarker, PoolGatePolicy } from "./types.js";

export interface GatePolicy {
  readonly poolId: string;
  readonly markerLabel: string;
}

export type GateMarkerLoadResult =
  | { readonly status: "absent" }
  | { readonly status: "invalid"; readonly detail: string }
  | { readonly status: "ok"; readonly marker: GateMarker };

function parseGateMarker(parsed: Partial<GateMarker>): GateMarker | null {
  if (typeof parsed.capHardStops !== "boolean" || typeof parsed.subscriptionBilled !== "boolean") {
    return null;
  }
  return {
    capHardStops: parsed.capHardStops,
    subscriptionBilled: parsed.subscriptionBilled,
    ...(typeof parsed.confirmedAt === "string" ? { confirmedAt: parsed.confirmedAt } : {}),
    ...(typeof parsed.pool === "string" ? { pool: parsed.pool } : {}),
  };
}

/** Load gate attestation from disk with absent vs corrupt distinction. */
export function loadGateMarkerFromFile(path: string): GateMarkerLoadResult {
  if (!existsSync(path)) {
    return { status: "absent" };
  }
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<GateMarker>;
    const marker = parseGateMarker(parsed);
    if (marker === null) {
      return {
        status: "invalid",
        detail: "required boolean fields capHardStops and subscriptionBilled missing or wrong type",
      };
    }
    return { status: "ok", marker };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return { status: "invalid", detail: `JSON parse failed: ${detail}` };
  }
}

/**
 * Evaluate spend-safety gate for one agent pool.
 * Orchestrator must refuse credentialed runs when not allowed.
 */
export function evaluateGateForPool(
  loadResult: GateMarkerLoadResult,
  policy: GatePolicy,
): GateDecision {
  if (loadResult.status === "absent") {
    return {
      allowed: false,
      reason:
        `${policy.markerLabel} marker absent — no credentialed run permitted for pool "${policy.poolId}". ` +
        "A human must confirm subscription-only billing with hard caps and record the attestation file.",
    };
  }

  if (loadResult.status === "invalid") {
    return {
      allowed: false,
      reason:
        `${policy.markerLabel} marker invalid at pool "${policy.poolId}" — ${loadResult.detail}. ` +
        "Fix or replace the attestation JSON (see operator/README.md).",
    };
  }

  const marker = loadResult.marker;

  if (marker.pool !== undefined && marker.pool !== policy.poolId) {
    return {
      allowed: false,
      reason: `${policy.markerLabel} marker pool "${marker.pool}" does not match selected pool "${policy.poolId}".`,
    };
  }

  const missing: string[] = [];
  if (!marker.capHardStops) {
    missing.push("hard spend cap confirmed (on-demand disabled or equivalent)");
  }
  if (!marker.subscriptionBilled) {
    missing.push("subscription-billed auth path confirmed (not metered API fallback)");
  }

  if (missing.length > 0) {
    return {
      allowed: false,
      reason: `${policy.markerLabel} incomplete for pool "${policy.poolId}" — unconfirmed: ${missing.join("; ")}`,
    };
  }

  return { allowed: true };
}

export function gatePolicyForPool(pool: PoolGatePolicy): GatePolicy {
  return {
    poolId: pool.gatePoolId,
    markerLabel: pool.gateMarkerLabel,
  };
}
