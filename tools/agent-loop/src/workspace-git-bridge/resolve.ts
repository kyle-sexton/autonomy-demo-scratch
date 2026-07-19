import { existsSync, readFileSync } from "node:fs";
import { join, normalize, resolve } from "node:path";

import { detectWorkspaceGitLayout, parseGitdirPointer } from "./detect-layout.js";
import {
  CONTAINER_BARE_GIT_MOUNT,
  type GitBridgeMode,
  type GitBridgePolicy,
  type ResolveWorkspaceGitBridgeInput,
  type WorkspaceGitBridge,
} from "./types.js";

const WINDOWS_OR_UNIX_ABSOLUTE_PATTERN = /^[A-Za-z]:\//u;
const PATH_SEGMENT_SPLIT_PATTERN = /[/\\]/u;

function emptyBridge(
  layout: WorkspaceGitBridge["layout"],
  mode: GitBridgeMode,
): WorkspaceGitBridge {
  return { layout, mode, bindMounts: [], containerEnv: {} };
}

function resolveEffectiveMode(
  policy: GitBridgePolicy,
  layout: WorkspaceGitBridge["layout"],
): GitBridgeMode {
  if (policy === "unavailable") {
    return "unavailable";
  }
  if (layout === "none") {
    return "unavailable";
  }
  if (layout === "plain") {
    return policy === "read" ? "read" : "read-write";
  }
  if (policy === "auto" || policy === "read-write") {
    return "read-write";
  }
  return policy;
}

/** Resolve host path from worktree admin `commondir` (typically `../..`). */
export function resolveBareHostPathFromAdminDir(worktreeAdminHostPath: string): string | undefined {
  const commondirPath = join(worktreeAdminHostPath, "commondir");
  if (!existsSync(commondirPath)) {
    return undefined;
  }
  try {
    const relative = readFileSync(commondirPath, "utf8").trim();
    if (relative === "") {
      return undefined;
    }
    return normalize(resolve(worktreeAdminHostPath, relative));
  } catch {
    return undefined;
  }
}

export function resolveLinkedWorktreeAdminPath(
  hostWorkspacePath: string,
  gitdirRaw: string,
): string | undefined {
  const trimmed = gitdirRaw.trim();
  if (trimmed === "") {
    return undefined;
  }
  if (WINDOWS_OR_UNIX_ABSOLUTE_PATTERN.test(trimmed) || trimmed.startsWith("/")) {
    return normalize(trimmed);
  }
  return normalize(resolve(hostWorkspacePath, trimmed));
}

/** Build session git bridge for linked bare-hub worktrees. */
export function resolveWorkspaceGitBridge(
  input: ResolveWorkspaceGitBridgeInput,
): WorkspaceGitBridge {
  const layout = detectWorkspaceGitLayout(input.hostWorkspacePath);
  const policy: GitBridgePolicy = input.gitBridgePolicy ?? "auto";
  const mode = resolveEffectiveMode(policy, layout);

  if (layout === "none" || mode === "unavailable") {
    return emptyBridge(layout, "unavailable");
  }

  if (layout === "plain") {
    return emptyBridge("plain", mode);
  }

  const gitPointerPath = join(input.hostWorkspacePath, ".git");
  let gitdirRaw: string | undefined;
  try {
    gitdirRaw = parseGitdirPointer(readFileSync(gitPointerPath, "utf8"));
  } catch {
    return emptyBridge("linked", "unavailable");
  }

  if (gitdirRaw === undefined) {
    return emptyBridge("linked", "unavailable");
  }

  const worktreeAdminHostPath = resolveLinkedWorktreeAdminPath(input.hostWorkspacePath, gitdirRaw);
  if (worktreeAdminHostPath === undefined || !existsSync(worktreeAdminHostPath)) {
    return emptyBridge("linked", "unavailable");
  }

  const bareHostPath = resolveBareHostPathFromAdminDir(worktreeAdminHostPath);
  if (bareHostPath === undefined || !existsSync(bareHostPath)) {
    return emptyBridge("linked", "unavailable");
  }

  const worktreeName = worktreeAdminHostPath
    .split(PATH_SEGMENT_SPLIT_PATTERN)
    .filter(Boolean)
    .at(-1);
  if (worktreeName === undefined || worktreeName === "") {
    return emptyBridge("linked", "unavailable");
  }

  const containerGitDir = `${CONTAINER_BARE_GIT_MOUNT}/worktrees/${worktreeName}`;
  const readOnly = mode === "read";

  return {
    layout: "linked",
    mode,
    bindMounts: [
      {
        hostPath: bareHostPath,
        containerPath: CONTAINER_BARE_GIT_MOUNT,
        ...(readOnly ? { readOnly: true } : {}),
      },
    ],
    containerEnv: {
      GIT_DIR: containerGitDir,
      GIT_WORK_TREE: input.containerWorkspacePath,
      GIT_COMMON_DIR: CONTAINER_BARE_GIT_MOUNT,
    },
  };
}
