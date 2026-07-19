import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { GitBridgePolicy } from "../workspace-git-bridge/types.js";

export const CAPABILITIES_DIR = "capabilities";

export type VerifyPlane = "host" | "container" | "both";

export interface CapabilityDependencies {
  readonly node: boolean;
  readonly dotnet: boolean;
}

export interface CapabilityProfile {
  readonly id: string;
  readonly gitBridge: GitBridgePolicy;
  readonly verifyPlane: VerifyPlane;
  readonly dependencies: CapabilityDependencies;
}

export interface CapabilitiesResolved {
  readonly profileId: string;
  readonly verifyPlane: VerifyPlane;
  readonly gitBridge: {
    readonly layout: string;
    readonly mode: string;
    readonly gitStatusExit: number | null;
  };
  readonly dependencies: Readonly<Record<string, boolean>>;
}

const PROFILE_CACHE = new Map<string, CapabilityProfile>();

export function loadCapabilityProfile(
  profileId: string,
  agentLoopProjectRoot: string,
): CapabilityProfile {
  const cached = PROFILE_CACHE.get(profileId);
  if (cached !== undefined) {
    return cached;
  }

  const path = join(agentLoopProjectRoot, CAPABILITIES_DIR, `${profileId}.json`);
  const raw = readFileSync(path, "utf8");
  const parsed = JSON.parse(raw) as CapabilityProfile;
  if (parsed.id !== profileId) {
    throw new Error(`Capability profile id mismatch: file ${profileId}.json has id ${parsed.id}`);
  }
  PROFILE_CACHE.set(profileId, parsed);
  return parsed;
}

export function buildCapabilitiesResolved(input: {
  readonly profile: CapabilityProfile;
  readonly gitBridgeLayout: string;
  readonly gitBridgeMode: string;
  readonly gitStatusExit: number | null;
  readonly observedDependencies: Readonly<Record<string, boolean>>;
}): CapabilitiesResolved {
  return {
    profileId: input.profile.id,
    verifyPlane: input.profile.verifyPlane,
    gitBridge: {
      layout: input.gitBridgeLayout,
      mode: input.gitBridgeMode,
      gitStatusExit: input.gitStatusExit,
    },
    dependencies: { ...input.observedDependencies },
  };
}

/** Clear profile cache — test helper. */
export function clearCapabilityProfileCache(): void {
  PROFILE_CACHE.clear();
}
