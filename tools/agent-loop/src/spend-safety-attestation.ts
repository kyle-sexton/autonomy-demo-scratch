import { type GateMarkerLoadResult, loadGateMarkerFromFile } from "./gate.js";
import type { GateMarker } from "./types.js";

/** Gitignored operator attestation directory (see `operator/README.md`). */
export const OPERATOR_DIRECTORY = "operator";

export const SPEND_SAFETY_ATTESTATION_EXAMPLE = "operator/spend-safety-attestation.example.json";

/** Load spend-safety attestation with absent vs corrupt distinction. */
export function loadSpendSafetyAttestationResult(primaryPath: string): GateMarkerLoadResult {
  return loadGateMarkerFromFile(primaryPath);
}

/** Load spend-safety attestation from the configured operator path. */
export function loadSpendSafetyAttestation(primaryPath: string): GateMarker | null {
  const result = loadSpendSafetyAttestationResult(primaryPath);
  return result.status === "ok" ? result.marker : null;
}
