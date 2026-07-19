import { existsSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";

import { detectWorkspaceGitLayout, parseGitdirPointer } from "./detect-layout.js";
import { resolveBareHostPathFromAdminDir, resolveLinkedWorktreeAdminPath } from "./resolve.js";

/** Remove stale `index.lock` in the linked worktree admin dir before container git writes. */
export function clearStaleWorktreeIndexLock(hostWorkspacePath: string): void {
  if (detectWorkspaceGitLayout(hostWorkspacePath) !== "linked") {
    return;
  }
  const gitPointerPath = join(hostWorkspacePath, ".git");
  let gitdirRaw: string | undefined;
  try {
    gitdirRaw = parseGitdirPointer(readFileSync(gitPointerPath, "utf8"));
  } catch {
    return;
  }
  if (gitdirRaw === undefined) {
    return;
  }
  const worktreeAdminHostPath = resolveLinkedWorktreeAdminPath(hostWorkspacePath, gitdirRaw);
  if (
    worktreeAdminHostPath === undefined ||
    resolveBareHostPathFromAdminDir(worktreeAdminHostPath) === undefined
  ) {
    return;
  }
  const lockPath = join(worktreeAdminHostPath, "index.lock");
  if (!existsSync(lockPath)) {
    return;
  }
  try {
    unlinkSync(lockPath);
  } catch {
    // Another git process holds the lock — leave it for git to report.
  }
}
