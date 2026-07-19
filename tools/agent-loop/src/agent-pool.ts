import { selectAdapter } from "./adapters/index.js";
import { CODEX_AUTH_CONTAINER_PATH } from "./codex-auth.js";
import { GROK_AUTH_CONTAINER_PATH } from "./grok-auth.js";
import type {
  PoolCredentialBindMount,
  PoolLocalOverride,
  PoolsLocalConfig,
} from "./pools-config.js";
import { resolveCredentialBindMounts } from "./pools-config.js";
import type { AgentCliAdapter, AgentCliKind, WorkspaceBindMount } from "./types.js";

const CURSOR_IMAGE = "agent-loop-cursor:thin";
const CURSOR_CLOUD_PARITY_IMAGE = "agent-loop-cursor:cloud-parity";
const CLAUDE_IMAGE = "agent-loop-claude:thin";
const CODEX_IMAGE = "agent-loop-codex:thin";
const GROK_IMAGE = "agent-loop-grok:thin";

const GATE_MARKER_CURSOR = "operator/spend-safety-attestation-cursor.json";
const GATE_MARKER_CLAUDE = "operator/spend-safety-attestation-claude.json";
const GATE_MARKER_CODEX = "operator/spend-safety-attestation-codex.json";
const GATE_MARKER_GROK = "operator/spend-safety-attestation-grok.json";

/** How the pool treats medley hook scripts inside the container (host verify + Lefthook remain authoritative). */
export type InContainerHooks = "suppressed" | "native" | "none";

const CODEX_DEFAULT_CREDENTIAL_MOUNTS: readonly PoolCredentialBindMount[] = [
  {
    hostPath: "~/.codex/auth.json",
    containerPath: CODEX_AUTH_CONTAINER_PATH,
    readOnly: true,
  },
];

const GROK_DEFAULT_CREDENTIAL_MOUNTS: readonly PoolCredentialBindMount[] = [
  {
    hostPath: "~/.grok/auth.json",
    containerPath: GROK_AUTH_CONTAINER_PATH,
    readOnly: true,
  },
];

/**
 * One credential + CLI + image combination the orchestrator can run.
 * Adapter argv is resolved via {@link resolvePoolAdapter} — not stored on the row.
 */
export interface AgentPool {
  readonly id: string;
  readonly cli: AgentCliKind;
  /** OCI image tag built from `docker/<cli>/Dockerfile` (see ARCHITECTURE.md). */
  readonly containerImage: string;
  /** Gitignored attestation path relative to project root (or absolute override in pools.local.jsonc). */
  readonly gateMarkerFilename: string;
  /** Expected `pool` field in the gate marker JSON when present. */
  readonly gatePoolId: string;
  readonly gateMarkerLabel: string;
  /** Host paths that must exist before launch (e.g. Codex auth.json). */
  readonly requiredHostPaths?: readonly string[];
  /** Default credential bind mounts when pools.local.jsonc omits overrides. */
  readonly defaultCredentialBindMounts?: readonly PoolCredentialBindMount[];
  /** In-container hook policy for this pool row. */
  readonly inContainerHooks: InContainerHooks;
  /** Declarative capability profile (`capabilities/<id>.json`). */
  readonly capabilityProfileId: string;
}

export const CURSOR_AGENT_POOL: AgentPool = {
  id: "cursor-default",
  cli: "cursor",
  containerImage: CURSOR_IMAGE,
  gateMarkerFilename: GATE_MARKER_CURSOR,
  gatePoolId: "cursor-default",
  gateMarkerLabel: "Cursor spend-safety attestation",
  inContainerHooks: "suppressed",
  capabilityProfileId: "thin",
};

/** Ubuntu + `tools/cloud-setup/setup.sh` — mirrors Cursor Cloud install for local container runs. */
export const CURSOR_CLOUD_PARITY_AGENT_POOL: AgentPool = {
  id: "cursor-cloud-parity",
  cli: "cursor",
  containerImage: CURSOR_CLOUD_PARITY_IMAGE,
  gateMarkerFilename: GATE_MARKER_CURSOR,
  gatePoolId: "cursor-cloud-parity",
  gateMarkerLabel: "Cursor spend-safety attestation (cloud-parity image)",
  inContainerHooks: "suppressed",
  capabilityProfileId: "cloud-parity",
};

export const CLAUDE_AGENT_POOL: AgentPool = {
  id: "claude-default",
  cli: "claude",
  containerImage: CLAUDE_IMAGE,
  gateMarkerFilename: GATE_MARKER_CLAUDE,
  gatePoolId: "claude-default",
  gateMarkerLabel: "Claude spend-safety attestation",
  inContainerHooks: "native",
  capabilityProfileId: "thin",
};

export const CODEX_AGENT_POOL: AgentPool = {
  id: "codex-default",
  cli: "codex",
  containerImage: CODEX_IMAGE,
  gateMarkerFilename: GATE_MARKER_CODEX,
  gatePoolId: "codex-default",
  gateMarkerLabel: "Codex spend-safety attestation",
  requiredHostPaths: ["~/.codex/auth.json"],
  defaultCredentialBindMounts: CODEX_DEFAULT_CREDENTIAL_MOUNTS,
  inContainerHooks: "none",
  capabilityProfileId: "thin",
};

export const GROK_AGENT_POOL: AgentPool = {
  id: "grok-default",
  cli: "grok",
  containerImage: GROK_IMAGE,
  gateMarkerFilename: GATE_MARKER_GROK,
  gatePoolId: "grok-default",
  gateMarkerLabel: "Grok spend-safety attestation",
  requiredHostPaths: ["~/.grok/auth.json"],
  defaultCredentialBindMounts: GROK_DEFAULT_CREDENTIAL_MOUNTS,
  inContainerHooks: "none",
  capabilityProfileId: "thin",
};

const BUILTIN_POOLS: Readonly<Record<string, AgentPool>> = {
  [CURSOR_AGENT_POOL.id]: CURSOR_AGENT_POOL,
  [CURSOR_CLOUD_PARITY_AGENT_POOL.id]: CURSOR_CLOUD_PARITY_AGENT_POOL,
  [CLAUDE_AGENT_POOL.id]: CLAUDE_AGENT_POOL,
  [CODEX_AGENT_POOL.id]: CODEX_AGENT_POOL,
  [GROK_AGENT_POOL.id]: GROK_AGENT_POOL,
};

/** Resolve headless CLI adapter for a pool row (SSOT: {@link selectAdapter}). */
export function resolvePoolAdapter(pool: Pick<AgentPool, "cli">): AgentCliAdapter {
  return selectAdapter(pool.cli);
}

export function listBuiltinPoolIds(): readonly string[] {
  return Object.keys(BUILTIN_POOLS);
}

function applyPoolOverride(base: AgentPool, override: PoolLocalOverride | undefined): AgentPool {
  if (override?.enabled === false) {
    throw new Error(`Agent pool "${base.id}" is disabled in pools.local.jsonc.`);
  }
  const containerImage =
    override?.containerImage !== undefined && override.containerImage.trim() !== ""
      ? override.containerImage.trim()
      : base.containerImage;
  if (containerImage === base.containerImage) {
    return base;
  }
  return { ...base, containerImage };
}

export function resolveAgentPool(
  poolId: string | undefined,
  _projectRoot: string,
  poolsConfig: PoolsLocalConfig = {},
): AgentPool {
  const selectedId =
    poolId !== undefined && poolId.trim() !== ""
      ? poolId.trim()
      : (poolsConfig.defaultPoolId ?? CURSOR_AGENT_POOL.id);

  const base = BUILTIN_POOLS[selectedId];
  if (base === undefined) {
    throw new Error(
      `Unknown agent pool "${selectedId}". Known pools: ${listBuiltinPoolIds().join(", ")}`,
    );
  }

  const override = poolsConfig.pools?.[selectedId];
  if (override?.enabled === false) {
    throw new Error(`Agent pool "${selectedId}" is disabled in pools.local.jsonc.`);
  }

  return applyPoolOverride(base, override);
}

export function resolvePoolAdditionalBindMounts(
  pool: AgentPool,
  projectRoot: string,
  poolsConfig: PoolsLocalConfig,
): readonly WorkspaceBindMount[] {
  const overrideMounts = poolsConfig.pools?.[pool.id]?.credentialBindMounts;
  const configured = resolveCredentialBindMounts(overrideMounts, projectRoot);
  if (configured.length > 0) {
    return configured;
  }
  if (
    pool.defaultCredentialBindMounts !== undefined &&
    pool.defaultCredentialBindMounts.length > 0
  ) {
    return resolveCredentialBindMounts(pool.defaultCredentialBindMounts, projectRoot);
  }
  return [];
}
