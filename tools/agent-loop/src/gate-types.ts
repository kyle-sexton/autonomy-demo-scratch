/** Operator attestation before credentialed runs (per pool row). */
export interface GateMarker {
  readonly capHardStops: boolean;
  readonly subscriptionBilled: boolean;
  readonly confirmedAt?: string;
  readonly pool?: string;
}

export type GateDecision =
  | { readonly allowed: true }
  | { readonly allowed: false; readonly reason: string };

/** Spend-safety gate policy fields carried on an {@link AgentPool} row. */
export interface PoolGatePolicy {
  readonly gatePoolId: string;
  readonly gateMarkerLabel: string;
}
