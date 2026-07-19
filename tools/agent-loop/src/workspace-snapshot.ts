import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

import type { WorkspaceRelativePath } from "./workspace-path.js";
import { resolvePathUnderRoot } from "./workspace-path.js";

export interface GitSnapshot {
  readonly statusShort: string;
  readonly diffStat: string;
  readonly untrackedAtRoot: readonly string[];
}

const QUOTED_PATH_PATTERN = /^"(.*)"$/u;
/** Known tracked root manifests — not flagged as junk when newly untracked during a run. */
const ROOT_MANIFEST_ALLOWLIST = new Set([
  "AGENTS.md",
  "CLAUDE.md",
  "CLAUDE.local.md.template",
  "Directory.Build.props",
  "Directory.Build.targets",
  "Directory.Packages.props",
  "Medley.slnx",
  "README.md",
  "REVIEW.md",
  "global.json",
  "lefthook.yml",
  "nuget.config",
  "package-lock.json",
  "package.json",
  "vitest.config.base.ts",
  "PSScriptAnalyzerSettings.psd1",
]);

function runGit(args: readonly string[], cwd: string): string {
  const result = spawnSync("git", [...args], {
    cwd,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.error !== undefined) {
    return `git error: ${result.error.message}`;
  }
  if (result.status !== 0) {
    const stderr = result.stderr?.trim() ?? "";
    return stderr.length > 0 ? stderr : `git exit ${String(result.status)}`;
  }
  return result.stdout?.trimEnd() ?? "";
}

/** Parse `git status --short` for untracked paths at repository root only. */
export function parseUntrackedAtRoot(statusShort: string): string[] {
  const found: string[] = [];
  for (const line of statusShort.split("\n")) {
    const trimmed = line.trimEnd();
    if (!trimmed.startsWith("?? ")) {
      continue;
    }
    const rawPath = trimmed.slice(3).trim();
    const path = rawPath.replace(QUOTED_PATH_PATTERN, "$1");
    if (path.includes("/") || path.includes("\\")) {
      continue;
    }
    if (path.startsWith(".")) {
      continue;
    }
    found.push(path);
  }
  return found.sort((a, b) => a.localeCompare(b));
}

/** Untracked root files that are not known manifests (likely agent junk). */
export function detectRootJunk(untrackedAtRoot: readonly string[]): string[] {
  return untrackedAtRoot.filter((name) => !ROOT_MANIFEST_ALLOWLIST.has(name));
}

export function captureGitSnapshot(workspaceRoot: string): GitSnapshot {
  const statusShort = runGit(["status", "--short", "--untracked-files=all"], workspaceRoot);
  const diffStat = runGit(["diff", "--stat", "HEAD"], workspaceRoot);
  const untrackedAtRoot = parseUntrackedAtRoot(statusShort);
  return { statusShort, diffStat, untrackedAtRoot };
}

export interface SnapshotDiff {
  readonly newUntrackedAtRoot: readonly string[];
  readonly newRootJunk: readonly string[];
}

export function diffSnapshots(before: GitSnapshot, after: GitSnapshot): SnapshotDiff {
  const beforeSet = new Set(before.untrackedAtRoot);
  const newUntrackedAtRoot = after.untrackedAtRoot.filter((p) => !beforeSet.has(p));
  return {
    newUntrackedAtRoot,
    newRootJunk: detectRootJunk(newUntrackedAtRoot),
  };
}

export function resolveRepoRelativePath(input: WorkspaceRelativePath): string {
  return resolvePathUnderRoot(input);
}

export function fileExistsAt(
  input: WorkspaceRelativePath & { readonly relativePath: string | undefined },
): boolean {
  const relativePath = input.relativePath?.trim();
  if (relativePath === undefined || relativePath === "") {
    return false;
  }
  return existsSync(resolveRepoRelativePath({ workspaceRoot: input.workspaceRoot, relativePath }));
}
