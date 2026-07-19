import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";

import type { WorkspaceBindMount } from "./types.js";

export const POOLS_LOCAL_FILENAME = "pools.local.jsonc";

export const POOLS_EXAMPLE_FILENAME = "pools.example.jsonc";

export interface PoolLocalOverride {
  readonly enabled?: boolean;
  readonly containerImage?: string;
  readonly gateMarkerFile?: string;
  readonly credentialBindMounts?: readonly PoolCredentialBindMount[];
}

export interface PoolCredentialBindMount {
  readonly hostPath: string;
  readonly containerPath: string;
  readonly readOnly?: boolean;
}

export interface PoolsLocalConfig {
  readonly defaultPoolId?: string;
  readonly pools?: Readonly<Record<string, PoolLocalOverride>>;
}

const PATH_TRAVERSAL_PATTERN = /\.\./;

/** Strip line and block comments outside JSON strings so JSON.parse accepts jsonc operator files. */
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: single-pass jsonc comment strip state machine
export function stripJsonComments(raw: string): string {
  let result = "";
  let inString = false;
  let escaped = false;
  let index = 0;

  while (index < raw.length) {
    const char = raw[index] ?? "";
    if (inString) {
      result += char;
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === '"') {
        inString = false;
      }
      index += 1;
      continue;
    }

    if (char === '"') {
      inString = true;
      result += char;
      index += 1;
      continue;
    }

    if (char === "/" && raw[index + 1] === "/") {
      while (index < raw.length && raw[index] !== "\n") {
        index += 1;
      }
      continue;
    }

    if (char === "/" && raw[index + 1] === "*") {
      index += 2;
      while (index < raw.length - 1 && !(raw[index] === "*" && raw[index + 1] === "/")) {
        index += 1;
      }
      index += 2;
      continue;
    }

    result += char;
    index += 1;
  }

  return result;
}

function validateCredentialBindMount(mount: unknown, context: string): PoolCredentialBindMount {
  if (mount === null || typeof mount !== "object") {
    throw new PoolsLocalConfigError(`${context}: credential bind mount must be an object`);
  }
  const record = mount as Record<string, unknown>;
  const hostPath = record["hostPath"];
  const containerPath = record["containerPath"];
  if (typeof hostPath !== "string" || hostPath.trim() === "") {
    throw new PoolsLocalConfigError(`${context}: hostPath must be a non-empty string`);
  }
  if (typeof containerPath !== "string" || containerPath.trim() === "") {
    throw new PoolsLocalConfigError(`${context}: containerPath must be a non-empty string`);
  }
  if (PATH_TRAVERSAL_PATTERN.test(hostPath) || PATH_TRAVERSAL_PATTERN.test(containerPath)) {
    throw new PoolsLocalConfigError(`${context}: bind mount paths must not contain '..'`);
  }
  if (record["readOnly"] !== undefined && typeof record["readOnly"] !== "boolean") {
    throw new PoolsLocalConfigError(`${context}: readOnly must be a boolean when set`);
  }
  return {
    hostPath: hostPath.trim(),
    containerPath: containerPath.trim(),
    ...(record["readOnly"] === true ? { readOnly: true } : {}),
  };
}

function validatePoolOverride(poolId: string, override: unknown): PoolLocalOverride {
  if (override === null || typeof override !== "object") {
    throw new PoolsLocalConfigError(`pools.${poolId}: override must be an object`);
  }
  const record = override as Record<string, unknown>;
  const result: {
    enabled?: boolean;
    containerImage?: string;
    gateMarkerFile?: string;
    credentialBindMounts?: PoolCredentialBindMount[];
  } = {};

  if (record["enabled"] !== undefined) {
    if (typeof record["enabled"] !== "boolean") {
      throw new PoolsLocalConfigError(`pools.${poolId}.enabled must be a boolean`);
    }
    result.enabled = record["enabled"];
  }
  if (record["containerImage"] !== undefined) {
    if (typeof record["containerImage"] !== "string") {
      throw new PoolsLocalConfigError(`pools.${poolId}.containerImage must be a string`);
    }
    result.containerImage = record["containerImage"];
  }
  if (record["gateMarkerFile"] !== undefined) {
    if (typeof record["gateMarkerFile"] !== "string") {
      throw new PoolsLocalConfigError(`pools.${poolId}.gateMarkerFile must be a string`);
    }
    result.gateMarkerFile = record["gateMarkerFile"];
  }
  if (record["credentialBindMounts"] !== undefined) {
    if (!Array.isArray(record["credentialBindMounts"])) {
      throw new PoolsLocalConfigError(`pools.${poolId}.credentialBindMounts must be an array`);
    }
    result.credentialBindMounts = record["credentialBindMounts"].map((mount, index) =>
      validateCredentialBindMount(mount, `pools.${poolId}.credentialBindMounts[${String(index)}]`),
    );
  }

  return result;
}

export function parsePoolsLocalConfig(raw: string): PoolsLocalConfig {
  const parsed = JSON.parse(stripJsonComments(raw)) as PoolsLocalConfig;
  let pools: Record<string, PoolLocalOverride> | undefined;
  if (parsed.pools !== undefined) {
    if (typeof parsed.pools !== "object" || parsed.pools === null || Array.isArray(parsed.pools)) {
      throw new PoolsLocalConfigError("pools must be an object");
    }
    pools = {};
    for (const [poolId, override] of Object.entries(parsed.pools)) {
      pools[poolId] = validatePoolOverride(poolId, override);
    }
  }

  return {
    ...(typeof parsed.defaultPoolId === "string" && parsed.defaultPoolId.trim() !== ""
      ? { defaultPoolId: parsed.defaultPoolId.trim() }
      : {}),
    ...(pools !== undefined ? { pools } : {}),
  };
}

export class PoolsLocalConfigError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "PoolsLocalConfigError";
  }
}

/** Load gitignored `pools.local.jsonc` when present; returns `{}` when absent. */
export function loadPoolsLocalConfig(projectRoot: string): PoolsLocalConfig {
  const path = join(projectRoot, POOLS_LOCAL_FILENAME);
  if (!existsSync(path)) {
    return {};
  }
  try {
    return parsePoolsLocalConfig(readFileSync(path, "utf8"));
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new PoolsLocalConfigError(
      `Invalid ${POOLS_LOCAL_FILENAME} at ${path}: ${detail}. Fix JSON/JSONC syntax or remove the file to use built-in pool defaults.`,
      { cause: error },
    );
  }
}

function expandHomePath(rawPath: string): string {
  const trimmed = rawPath.trim();
  if (trimmed.startsWith("~/")) {
    return join(homedir(), trimmed.slice(2));
  }
  if (trimmed === "~") {
    return homedir();
  }
  return trimmed;
}

export function resolvePoolBindMountHostPath(rawPath: string, projectRoot: string): string {
  const expanded = expandHomePath(rawPath);
  return isAbsolute(expanded) ? expanded : resolve(projectRoot, expanded);
}

export function resolveCredentialBindMounts(
  mounts: readonly PoolCredentialBindMount[] | undefined,
  projectRoot: string,
): readonly WorkspaceBindMount[] {
  if (mounts === undefined || mounts.length === 0) {
    return [];
  }
  return mounts.map((mount) => ({
    hostPath: resolvePoolBindMountHostPath(mount.hostPath, projectRoot),
    containerPath: mount.containerPath,
    ...(mount.readOnly === true ? { readOnly: true } : {}),
  }));
}

export function resolveGateMarkerPath(
  projectRoot: string,
  poolId: string,
  defaultFilename: string,
  poolsConfig: PoolsLocalConfig,
): string {
  const override = poolsConfig.pools?.[poolId]?.gateMarkerFile;
  if (override !== undefined && override.trim() !== "") {
    const trimmed = override.trim();
    if (PATH_TRAVERSAL_PATTERN.test(trimmed)) {
      throw new PoolsLocalConfigError(`pools.${poolId}.gateMarkerFile must not contain '..'`);
    }
    if (isAbsolute(trimmed)) {
      return trimmed;
    }
    const resolved = resolve(projectRoot, trimmed);
    const rootResolved = resolve(projectRoot);
    if (resolved !== rootResolved && !resolved.startsWith(`${rootResolved}${sep}`)) {
      throw new PoolsLocalConfigError(
        `pools.${poolId}.gateMarkerFile resolves outside project root: ${trimmed}`,
      );
    }
    return resolved;
  }
  return join(projectRoot, defaultFilename);
}
