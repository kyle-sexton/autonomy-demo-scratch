import { spawnSync } from "node:child_process";
import { join } from "node:path";

import { CONTAINER_WORKSPACE_MOUNT, LOG_PREFIX } from "./constants.js";

const GIT_FOR_WINDOWS_EXEC_PATH_SUFFIX = "/mingw64/libexec/git-core";

/** Git for Windows pathconv form of `/workspace` (e.g. `C:/Program Files/Git/workspace`). */
function gitForWindowsInstallWorkspaceSentinel(): string | undefined {
  if (process.platform !== "win32") {
    return undefined;
  }
  const result = spawnSync("git", ["--exec-path"], { encoding: "utf8" });
  if (result.status !== 0) {
    return undefined;
  }
  const execPath = (result.stdout ?? "").trim().replace(/\\/gu, "/");
  if (!execPath.endsWith(GIT_FOR_WINDOWS_EXEC_PATH_SUFFIX)) {
    return undefined;
  }
  const installRoot = execPath.slice(0, -GIT_FOR_WINDOWS_EXEC_PATH_SUFFIX.length);
  return `${installRoot}/workspace`;
}

/** Container-only paths that must not appear in host env or persisted git config. */
export function containerWorkspaceSentinels(env: NodeJS.ProcessEnv): readonly string[] {
  const sentinels = new Set<string>([CONTAINER_WORKSPACE_MOUNT]);
  const mingwPrefix = env["MINGW_PREFIX"]?.trim();
  if (mingwPrefix !== undefined && mingwPrefix !== "") {
    sentinels.add(join(mingwPrefix, "workspace").replace(/\\/gu, "/"));
  }
  const gitForWindowsSentinel = gitForWindowsInstallWorkspaceSentinel();
  if (gitForWindowsSentinel !== undefined) {
    sentinels.add(gitForWindowsSentinel);
  }
  return [...sentinels];
}

function normalizePath(value: string): string {
  return value.trim().replace(/\\/gu, "/");
}

/** True when value is a container workspace mount path (POSIX or local MSYS pathconv form). */
export function isContainerWorkspaceSentinel(
  value: string | undefined,
  env: NodeJS.ProcessEnv,
): boolean {
  const trimmed = value?.trim();
  if (trimmed === undefined || trimmed === "") {
    return false;
  }
  const normalized = normalizePath(trimmed);
  return containerWorkspaceSentinels(env).some((sentinel) => sentinel === normalized);
}

/** True when a config value contains a container sentinel as a path segment or exact match. */
export function configValueContainsContainerSentinel(
  value: string | undefined,
  env: NodeJS.ProcessEnv,
): boolean {
  if (value === undefined || value.trim() === "") {
    return false;
  }
  if (isContainerWorkspaceSentinel(value, env)) {
    return true;
  }
  const normalized = normalizePath(value);
  return containerWorkspaceSentinels(env).some(
    (sentinel) => normalized.includes(sentinel) || normalized.startsWith(`${sentinel}/`),
  );
}

function runGitConfig(
  hostWorkspacePath: string,
  args: readonly string[],
): { readonly stdout: string; readonly status: number } {
  const result = spawnSync("git", ["-C", hostWorkspacePath, "config", ...args], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  return {
    stdout: (result.stdout ?? "").trim(),
    status: result.status ?? 1,
  };
}

function isGitRepository(hostWorkspacePath: string): boolean {
  const result = spawnSync("git", ["-C", hostWorkspacePath, "rev-parse", "--git-dir"], {
    encoding: "utf8",
  });
  return result.status === 0;
}

/** Parse `git config --local --list` into key/value pairs (last segment wins for duplicates). */
export function readLocalGitConfigEntries(
  hostWorkspacePath: string,
): ReadonlyArray<{ readonly key: string; readonly value: string }> {
  const { stdout, status } = runGitConfig(hostWorkspacePath, ["--local", "--list"]);
  if (status !== 0 || stdout === "") {
    return [];
  }
  const entries: Array<{ key: string; value: string }> = [];
  for (const line of stdout.split("\n")) {
    const trimmed = line.trimEnd();
    if (trimmed === "") {
      continue;
    }
    const eq = trimmed.indexOf("=");
    if (eq <= 0) {
      continue;
    }
    entries.push({
      key: trimmed.slice(0, eq),
      value: trimmed.slice(eq + 1),
    });
  }
  return entries;
}

export interface HostGitConfigViolation {
  readonly key: string;
  readonly value: string;
  readonly reason: string;
}

export interface HostGitConfigRepair {
  readonly key: string;
  readonly action: string;
}

/** Read `core.worktree` when set in the linked repo config (e.g. bare-hub `.bare/config`). */
export function readHostCoreWorktree(hostWorkspacePath: string): string | undefined {
  const { stdout, status } = runGitConfig(hostWorkspacePath, ["--get", "core.worktree"]);
  if (status !== 0 || stdout === "") {
    return undefined;
  }
  return stdout;
}

/**
 * Remove container `core.worktree` leaked into host git config by in-container git.
 * Returns true when a sentinel value was cleared.
 */
export function repairHostCoreWorktreeLeak(
  hostWorkspacePath: string,
  env: NodeJS.ProcessEnv,
): boolean {
  const worktree = readHostCoreWorktree(hostWorkspacePath);
  if (!isContainerWorkspaceSentinel(worktree, env)) {
    return false;
  }
  const { status } = runGitConfig(hostWorkspacePath, ["--unset", "core.worktree"]);
  return status === 0;
}

export function logRepairedHostCoreWorktreeLeak(
  hostWorkspacePath: string,
  worktree: string,
  logLine: (text: string) => void,
): void {
  logLine(
    `${LOG_PREFIX} repaired host git config: unset core.worktree=${JSON.stringify(worktree)} (container leak; repo ${hostWorkspacePath})`,
  );
}

/** Windows hosts pin core.filemode=false — see tools/bootstrap.sh check_git_filemode. */
export function hostRequiresCoreFilemodeFalse(): boolean {
  return process.platform === "win32";
}

/** Read `core.filemode` from repo-local config (shared `.git/config` on bind mounts). */
export function readHostCoreFilemode(hostWorkspacePath: string): string | undefined {
  const { stdout, status } = runGitConfig(hostWorkspacePath, ["--get", "core.filemode"]);
  if (status !== 0 || stdout === "") {
    return undefined;
  }
  return stdout;
}

/**
 * Reset `core.filemode` to false after Linux container git flips it on a Windows bind mount.
 * Returns true when the value was changed.
 */
export function repairHostCoreFilemodeLeak(hostWorkspacePath: string): boolean {
  if (!hostRequiresCoreFilemodeFalse()) {
    return false;
  }
  const current = readHostCoreFilemode(hostWorkspacePath);
  if (current === "false") {
    return false;
  }
  const { status } = runGitConfig(hostWorkspacePath, ["core.filemode", "false"]);
  return status === 0;
}

export function logRepairedHostCoreFilemodeLeak(
  hostWorkspacePath: string,
  previous: string | undefined,
  logLine: (text: string) => void,
): void {
  logLine(
    `${LOG_PREFIX} repaired host git config: core.filemode=false (was ${previous ?? "<unset>"}; container bind-mount leak; repo ${hostWorkspacePath})`,
  );
}

function readConfigValue(hostWorkspacePath: string, key: string): string | undefined {
  const { stdout, status } = runGitConfig(hostWorkspacePath, ["--get", key]);
  if (status !== 0 || stdout === "") {
    return undefined;
  }
  return stdout;
}

function readConfigValuesAll(hostWorkspacePath: string, key: string): readonly string[] {
  const { stdout, status } = runGitConfig(hostWorkspacePath, ["--get-all", key]);
  if (status !== 0 || stdout === "") {
    return [];
  }
  return stdout.split("\n").filter((line) => line.length > 0);
}

/** Audit repo-local git config for container bind-mount leaks. */
export function auditHostGitConfig(
  hostWorkspacePath: string,
  env: NodeJS.ProcessEnv,
): readonly HostGitConfigViolation[] {
  if (!isGitRepository(hostWorkspacePath)) {
    return [];
  }
  const violations: HostGitConfigViolation[] = [];

  const worktree = readHostCoreWorktree(hostWorkspacePath);
  if (isContainerWorkspaceSentinel(worktree, env)) {
    violations.push({
      key: "core.worktree",
      value: worktree ?? "",
      reason: "container-only worktree path",
    });
  }

  if (hostRequiresCoreFilemodeFalse()) {
    const filemode = readHostCoreFilemode(hostWorkspacePath);
    if (filemode !== "false") {
      violations.push({
        key: "core.filemode",
        value: filemode ?? "<unset>",
        reason: "Windows host requires core.filemode=false",
      });
    }
  }

  const autocrlf = readConfigValue(hostWorkspacePath, "core.autocrlf");
  if (autocrlf === "true") {
    violations.push({
      key: "core.autocrlf",
      value: autocrlf,
      reason: "repo SSOT requires core.autocrlf=false",
    });
  }

  for (const safeDir of readConfigValuesAll(hostWorkspacePath, "safe.directory")) {
    if (safeDir === "*") {
      violations.push({
        key: "safe.directory",
        value: safeDir,
        reason: "safe.directory=* weakens ownership checks",
      });
    }
  }

  const hooksPath = readConfigValue(hostWorkspacePath, "core.hooksPath");
  if (configValueContainsContainerSentinel(hooksPath, env)) {
    violations.push({
      key: "core.hooksPath",
      value: hooksPath ?? "",
      reason: "container path in core.hooksPath",
    });
  }

  for (const entry of readLocalGitConfigEntries(hostWorkspacePath)) {
    if (
      entry.key === "core.worktree" ||
      entry.key === "core.filemode" ||
      entry.key === "core.autocrlf" ||
      entry.key === "safe.directory" ||
      entry.key === "core.hooksPath"
    ) {
      continue;
    }
    if (configValueContainsContainerSentinel(entry.value, env)) {
      violations.push({
        key: entry.key,
        value: entry.value,
        reason: "container sentinel in config value",
      });
    }
  }

  return violations;
}

function repairAutocrlfLeak(hostWorkspacePath: string): boolean {
  const autocrlf = readConfigValue(hostWorkspacePath, "core.autocrlf");
  if (autocrlf !== "true") {
    return false;
  }
  const { status } = runGitConfig(hostWorkspacePath, ["core.autocrlf", "false"]);
  return status === 0;
}

function repairSafeDirectoryStar(hostWorkspacePath: string): boolean {
  const values = readConfigValuesAll(hostWorkspacePath, "safe.directory");
  if (!values.includes("*")) {
    return false;
  }
  const { status } = runGitConfig(hostWorkspacePath, ["--unset-all", "safe.directory", "\\*"]);
  return status === 0;
}

function repairHooksPathSentinel(hostWorkspacePath: string, env: NodeJS.ProcessEnv): boolean {
  const hooksPath = readConfigValue(hostWorkspacePath, "core.hooksPath");
  if (!configValueContainsContainerSentinel(hooksPath, env)) {
    return false;
  }
  const { status } = runGitConfig(hostWorkspacePath, ["--unset", "core.hooksPath"]);
  return status === 0;
}

function repairGenericSentinelEntries(
  hostWorkspacePath: string,
  env: NodeJS.ProcessEnv,
): readonly HostGitConfigRepair[] {
  const repairs: HostGitConfigRepair[] = [];
  const knownKeys = new Set([
    "core.worktree",
    "core.filemode",
    "core.autocrlf",
    "safe.directory",
    "core.hooksPath",
  ]);

  for (const entry of readLocalGitConfigEntries(hostWorkspacePath)) {
    if (knownKeys.has(entry.key)) {
      continue;
    }
    if (!configValueContainsContainerSentinel(entry.value, env)) {
      continue;
    }
    const { status } = runGitConfig(hostWorkspacePath, ["--unset", entry.key]);
    if (status === 0) {
      repairs.push({ key: entry.key, action: `unset (sentinel in value ${entry.value})` });
    }
  }
  return repairs;
}

/** Idempotent repair of known container git config leaks. */
export function repairHostGitConfigLeaks(
  hostWorkspacePath: string,
  env: NodeJS.ProcessEnv,
): readonly HostGitConfigRepair[] {
  if (!isGitRepository(hostWorkspacePath)) {
    return [];
  }
  const repairs: HostGitConfigRepair[] = [];

  const worktree = readHostCoreWorktree(hostWorkspacePath);
  if (
    isContainerWorkspaceSentinel(worktree, env) &&
    repairHostCoreWorktreeLeak(hostWorkspacePath, env)
  ) {
    repairs.push({ key: "core.worktree", action: "unset" });
  }

  const filemodeBefore = readHostCoreFilemode(hostWorkspacePath);
  if (repairHostCoreFilemodeLeak(hostWorkspacePath)) {
    repairs.push({
      key: "core.filemode",
      action: `set false (was ${filemodeBefore ?? "<unset>"})`,
    });
  }

  if (repairAutocrlfLeak(hostWorkspacePath)) {
    repairs.push({ key: "core.autocrlf", action: "set false" });
  }

  if (repairSafeDirectoryStar(hostWorkspacePath)) {
    repairs.push({ key: "safe.directory", action: "unset *" });
  }

  if (repairHooksPathSentinel(hostWorkspacePath, env)) {
    repairs.push({ key: "core.hooksPath", action: "unset" });
  }

  repairs.push(...repairGenericSentinelEntries(hostWorkspacePath, env));

  return repairs;
}

/** True when audit finds no violations. */
export function hostGitConfigIsClean(hostWorkspacePath: string, env: NodeJS.ProcessEnv): boolean {
  return auditHostGitConfig(hostWorkspacePath, env).length === 0;
}
