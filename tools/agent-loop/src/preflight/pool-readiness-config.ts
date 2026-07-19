import {
  type AgentPool,
  CLAUDE_AGENT_POOL,
  CODEX_AGENT_POOL,
  CURSOR_AGENT_POOL,
  CURSOR_CLOUD_PARITY_AGENT_POOL,
  GROK_AGENT_POOL,
} from "../agent-pool.js";
import { validateClaudeSubscriptionAuth } from "../claude-headless-config.js";
import { parsePoolsLocalConfig } from "../pools-config.js";

export interface PoolAuthProfile {
  readonly kind: "env" | "host-files" | "host-files-with-grok-cli";
  readonly label: string;
  readonly hostPaths?: readonly string[];
  readonly validateEnv?: (env: NodeJS.ProcessEnv) => string | undefined;
}

export interface PoolReadinessProfile {
  readonly pool: AgentPool;
  readonly dockerfilePath: string;
  readonly structuralTestScript: string;
  readonly tier0BuildScript: string;
  readonly attestationExampleFile: string;
  readonly auth: PoolAuthProfile;
  readonly expectedSessionBindMountCount: number;
  readonly complianceFile?: string;
}

const CLAUDE_COMPLIANCE_FILE = "context/compliance-posture.md";

export const POOL_READINESS_PROFILES: Readonly<Record<string, PoolReadinessProfile>> = {
  [CURSOR_AGENT_POOL.id]: {
    pool: CURSOR_AGENT_POOL,
    dockerfilePath: "Dockerfile",
    structuralTestScript: "scripts/verify-cursor-headless-writes.test.sh",
    tier0BuildScript: "build/verify-headless-writes.js",
    attestationExampleFile: "operator/spend-safety-attestation.example.json",
    auth: {
      kind: "env",
      label: "CURSOR_API_KEY in tools/agent-loop/.env or OS env",
    },
    expectedSessionBindMountCount: 2,
  },
  [CURSOR_CLOUD_PARITY_AGENT_POOL.id]: {
    pool: CURSOR_CLOUD_PARITY_AGENT_POOL,
    dockerfilePath: "docker/cursor/Dockerfile.cloud-parity",
    structuralTestScript: "scripts/verify-cursor-headless-writes.test.sh",
    tier0BuildScript: "build/verify-headless-writes.js",
    attestationExampleFile: "operator/spend-safety-attestation.example.json",
    auth: {
      kind: "env",
      label: "CURSOR_API_KEY in tools/agent-loop/.env or OS env",
    },
    expectedSessionBindMountCount: 2,
  },
  [CLAUDE_AGENT_POOL.id]: {
    pool: CLAUDE_AGENT_POOL,
    dockerfilePath: "docker/claude/Dockerfile",
    structuralTestScript: "scripts/verify-claude-headless-writes.test.sh",
    tier0BuildScript: "build/verify-claude-headless-writes.js",
    attestationExampleFile: "operator/spend-safety-attestation-claude.example.json",
    auth: {
      kind: "env",
      label: "CLAUDE_CODE_OAUTH_TOKEN; ANTHROPIC_API_KEY must stay unset",
      validateEnv: validateClaudeSubscriptionAuth,
    },
    expectedSessionBindMountCount: 0,
    complianceFile: CLAUDE_COMPLIANCE_FILE,
  },
  [CODEX_AGENT_POOL.id]: {
    pool: CODEX_AGENT_POOL,
    dockerfilePath: "docker/codex/Dockerfile",
    structuralTestScript: "scripts/verify-codex-headless-writes.test.sh",
    tier0BuildScript: "build/verify-codex-headless-writes.js",
    attestationExampleFile: "operator/spend-safety-attestation-codex.example.json",
    auth: {
      kind: "host-files",
      label: "~/.codex/auth.json on host",
      hostPaths: ["~/.codex/auth.json"],
    },
    expectedSessionBindMountCount: 0,
  },
  [GROK_AGENT_POOL.id]: {
    pool: GROK_AGENT_POOL,
    dockerfilePath: "docker/grok/Dockerfile",
    structuralTestScript: "scripts/verify-grok-headless-writes.test.sh",
    tier0BuildScript: "build/verify-grok-headless-writes.js",
    attestationExampleFile: "operator/spend-safety-attestation-grok.example.json",
    auth: {
      kind: "host-files-with-grok-cli",
      label: "~/.grok/auth.json and Grok CLI on host",
      hostPaths: ["~/.grok/auth.json"],
    },
    expectedSessionBindMountCount: 0,
  },
};

export const PREFLIGHT_POOL_IDS = Object.keys(POOL_READINESS_PROFILES);

export function resolvePoolReadinessProfile(poolId: string): PoolReadinessProfile | undefined {
  return POOL_READINESS_PROFILES[poolId];
}

export function poolEnabledInLocalConfig(raw: string, poolId: string): boolean {
  try {
    return parsePoolsLocalConfig(raw).pools?.[poolId]?.enabled === true;
  } catch {
    return false;
  }
}
