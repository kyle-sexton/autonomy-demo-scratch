/**
 * Domain types for the implement-only agent loop.
 *
 * Orchestrator = loop lifecycle. Adapter (GoF) = vendor CLI → container invocation.
 * Pool = one credential + CLI + image row. Prompt = all slice semantics.
 */

export type {
  AgentCliAdapter,
  ContainerInvocation,
  IterationContext,
} from "./adapter-types.js";
export type {
  GateDecision,
  GateMarker,
  PoolGatePolicy,
} from "./gate-types.js";
export type {
  AgentCliKind,
  AgentOutputFormat,
  CompletionResult,
  IterationDecision,
  RunSession,
  Sentinel,
  WorkspaceBindMount,
} from "./session-types.js";
