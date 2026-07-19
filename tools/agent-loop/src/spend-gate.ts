import type { AgentPool } from "./agent-pool.js";
import { evaluateGateForPool, gatePolicyForPool } from "./gate.js";
import {
  loadPoolsLocalConfig,
  type PoolsLocalConfig,
  resolveGateMarkerPath,
} from "./pools-config.js";
import { loadSpendSafetyAttestationResult } from "./spend-safety-attestation.js";

export interface SpendGateFailure {
  readonly exitCode: number;
  readonly message: string;
}

/** Refuse credentialed runs when spend-safety attestation is missing or incomplete. */
export function evaluateSpendGateOrError(
  pool: AgentPool,
  projectRoot: string,
  poolsConfig: PoolsLocalConfig,
  gateMarkerOverride?: string,
): SpendGateFailure | undefined {
  const gateMarkerPath =
    gateMarkerOverride ??
    resolveGateMarkerPath(projectRoot, pool.id, pool.gateMarkerFilename, poolsConfig);
  const gate = evaluateGateForPool(
    loadSpendSafetyAttestationResult(gateMarkerPath),
    gatePolicyForPool(pool),
  );
  if (!gate.allowed) {
    return {
      exitCode: 1,
      message:
        `${pool.gateMarkerLabel} REFUSED — ${gate.reason}. ` +
        `Record attestation at ${gateMarkerPath} (see operator/README.md).`,
    };
  }
  return undefined;
}

/** Load pools config; propagates {@link PoolsLocalConfigError} when the file is present but invalid. */
export function loadPoolsConfigForSpendGate(projectRoot: string): PoolsLocalConfig {
  return loadPoolsLocalConfig(projectRoot);
}
