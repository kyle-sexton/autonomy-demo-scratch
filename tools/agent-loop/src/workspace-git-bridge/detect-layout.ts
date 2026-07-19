import { existsSync, lstatSync, readFileSync, type Stats } from "node:fs";
import { join } from "node:path";

import type { WorkspaceGitLayout } from "./types.js";

const GITDIR_PREFIX = "gitdir:";
const LINE_BREAK_PATTERN = /\r?\n/u;

/** Parse `gitdir:` from a worktree `.git` pointer file. */
export function parseGitdirPointer(content: string): string | undefined {
  for (const line of content.split(LINE_BREAK_PATTERN)) {
    const trimmed = line.trim();
    if (trimmed.toLowerCase().startsWith(GITDIR_PREFIX)) {
      const value = trimmed.slice(GITDIR_PREFIX.length).trim();
      return value.length > 0 ? value : undefined;
    }
  }
  return undefined;
}

/** Classify workspace git layout from host `.git` entry. */
export function detectWorkspaceGitLayout(hostWorkspacePath: string): WorkspaceGitLayout {
  const gitPath = join(hostWorkspacePath, ".git");
  if (!existsSync(gitPath)) {
    return "none";
  }

  let stat: Stats;
  try {
    stat = lstatSync(gitPath);
  } catch {
    return "none";
  }

  if (stat.isDirectory()) {
    return "plain";
  }

  if (!stat.isFile()) {
    return "none";
  }

  try {
    const content = readFileSync(gitPath, "utf8");
    return parseGitdirPointer(content) !== undefined ? "linked" : "none";
  } catch {
    return "none";
  }
}
