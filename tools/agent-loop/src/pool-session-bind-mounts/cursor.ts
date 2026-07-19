import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, posix } from "node:path";

import type { AgentPool } from "../agent-pool.js";
import { CONTAINER_WORKSPACE_MOUNT } from "../constants.js";
import type { WorkspaceBindMount } from "../types.js";
import type { PoolSessionBindMountContext, PoolSessionBindMountResolver } from "./types.js";

export const POOL_SESSION_RUNTIME_DIR = "runtime";

const CLAUDE_SETTINGS_HEADLESS_FILENAME = "claude-settings.headless.json";
const CURSOR_HOOKS_DISABLED_FILENAME = "cursor-hooks.disabled.json";

const EMPTY_CURSOR_HOOKS = { version: 1, hooks: {} } as const;

const HEADLESS_GIT_CONFIG_DENY = ["Bash(git config *)", "Bash(git config:*)"] as const;

/** Shallow copy of Claude settings with the `hooks` key removed (container session only). */
export function stripHooksFromClaudeSettings(
  settings: Record<string, unknown>,
): Record<string, unknown> {
  const { hooks: _hooks, ...rest } = settings;
  return rest;
}

/** Merge headless container boundaries: no hooks, deny git config mutations. */
export function applyHeadlessContainerBoundaries(
  settings: Record<string, unknown>,
): Record<string, unknown> {
  const stripped = stripHooksFromClaudeSettings(settings);
  const permissionsRaw = stripped["permissions"];
  const permissions =
    permissionsRaw !== null && typeof permissionsRaw === "object" && !Array.isArray(permissionsRaw)
      ? { ...(permissionsRaw as Record<string, unknown>) }
      : {};

  const denyRaw = permissions["deny"];
  const denyList = Array.isArray(denyRaw) ? [...denyRaw.map(String)] : [];
  for (const rule of HEADLESS_GIT_CONFIG_DENY) {
    if (!denyList.includes(rule)) {
      denyList.push(rule);
    }
  }
  permissions["deny"] = denyList;

  return { ...stripped, permissions };
}

export function resolveClaudeSettingsHeadlessPath(
  agentLoopProjectRoot: string,
  runId: string,
): string {
  return join(
    agentLoopProjectRoot,
    POOL_SESSION_RUNTIME_DIR,
    runId,
    CLAUDE_SETTINGS_HEADLESS_FILENAME,
  );
}

export function resolveCursorHooksDisabledPath(
  agentLoopProjectRoot: string,
  runId: string,
): string {
  return join(
    agentLoopProjectRoot,
    POOL_SESSION_RUNTIME_DIR,
    runId,
    CURSOR_HOOKS_DISABLED_FILENAME,
  );
}

function writeHeadlessSessionArtifacts(options: {
  readonly workspaceRoot: string;
  readonly agentLoopProjectRoot: string;
  readonly runId: string;
}): { readonly settingsPath: string; readonly cursorHooksPath: string } {
  const settingsPath = join(options.workspaceRoot, ".claude/settings.json");
  if (!existsSync(settingsPath)) {
    throw new Error(
      `Cursor pool requires ${settingsPath} for in-container hook suppression; file is missing.`,
    );
  }
  const raw = readFileSync(settingsPath, "utf8");
  const settings = JSON.parse(raw) as Record<string, unknown>;
  const headless = applyHeadlessContainerBoundaries(settings);

  const settingsOutputPath = resolveClaudeSettingsHeadlessPath(
    options.agentLoopProjectRoot,
    options.runId,
  );
  const cursorHooksOutputPath = resolveCursorHooksDisabledPath(
    options.agentLoopProjectRoot,
    options.runId,
  );
  mkdirSync(dirname(settingsOutputPath), { recursive: true });
  writeFileSync(settingsOutputPath, `${JSON.stringify(headless, null, 2)}\n`, "utf8");
  writeFileSync(cursorHooksOutputPath, `${JSON.stringify(EMPTY_CURSOR_HOOKS, null, 2)}\n`, "utf8");

  return { settingsPath: settingsOutputPath, cursorHooksPath: cursorHooksOutputPath };
}

function buildSuppressionBindMounts(
  settingsHostPath: string,
  cursorHooksHostPath: string,
): readonly WorkspaceBindMount[] {
  return [
    {
      hostPath: settingsHostPath,
      containerPath: posix.join(CONTAINER_WORKSPACE_MOUNT, ".claude/settings.json"),
      readOnly: true,
    },
    {
      hostPath: cursorHooksHostPath,
      containerPath: posix.join(CONTAINER_WORKSPACE_MOUNT, ".cursor/hooks.json"),
      readOnly: true,
    },
  ];
}

/**
 * Cursor headless hook suppression — session-scoped bind mounts only.
 * Delete this module when Cursor documents stable headless hook disable or fixes CLI import.
 */
export const resolveCursorPoolSessionBindMounts: PoolSessionBindMountResolver = (
  pool: AgentPool,
  context: PoolSessionBindMountContext,
): readonly WorkspaceBindMount[] => {
  if (pool.inContainerHooks !== "suppressed") {
    return [];
  }
  const artifacts = writeHeadlessSessionArtifacts({
    workspaceRoot: context.workspaceRoot,
    agentLoopProjectRoot: context.agentLoopProjectRoot,
    runId: context.runId,
  });
  return buildSuppressionBindMounts(artifacts.settingsPath, artifacts.cursorHooksPath);
};
