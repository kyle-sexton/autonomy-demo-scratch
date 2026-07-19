import { statSync } from "node:fs";

import { ENV, readEnv } from "./env-keys.js";

const POSITIVE_INTEGER_PATTERN = /^\d+$/;

function parsePositiveInteger(raw: string | undefined): number | undefined {
  if (raw === undefined || raw.trim() === "") {
    return undefined;
  }
  const trimmed = raw.trim();
  if (!POSITIVE_INTEGER_PATTERN.test(trimmed)) {
    return undefined;
  }
  const value = Number.parseInt(trimmed, 10);
  return Number.isFinite(value) && value >= 0 ? value : undefined;
}

/** Non-root user for Claude `bypassPermissions` when the host omits explicit ids. */
export const CLAUDE_NON_ROOT_CONTAINER_USER = "1000:1000";

/**
 * Resolve `docker run --user uid:gid` for bind-mount ownership on Linux.
 * Precedence: env pair → workspace owner stat (linux only) → omit (Windows/macOS default).
 */
export function resolveContainerRunUser(
  workspacePath: string,
  platform: NodeJS.Platform = process.platform,
  envUid?: string,
  envGid?: string,
): string | undefined {
  const uid = parsePositiveInteger(envUid ?? readEnv(ENV.containerUid));
  const gid = parsePositiveInteger(envGid ?? readEnv(ENV.containerGid));
  if (uid !== undefined && gid !== undefined) {
    return `${uid}:${gid}`;
  }

  if (platform !== "linux") {
    return undefined;
  }

  try {
    const stats = statSync(workspacePath);
    return `${stats.uid}:${stats.gid}`;
  } catch {
    return undefined;
  }
}
