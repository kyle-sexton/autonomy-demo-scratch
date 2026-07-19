import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { clearStaleWorktreeIndexLock } from "./clear-stale-index-lock.js";

describe("clearStaleWorktreeIndexLock", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function makeLinkedWorktree(): { workspace: string; admin: string } {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-lock-"));
    roots.push(root);
    const bare = join(root, ".bare");
    const admin = join(bare, "worktrees", "slice");
    const workspace = join(root, "slice");
    mkdirSync(admin, { recursive: true });
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(admin, "commondir"), "../..\n", "utf8");
    writeFileSync(join(workspace, ".git"), `gitdir: ${admin.replace(/\\/gu, "/")}\n`, "utf8");
    return { workspace, admin };
  }

  it("should remove index.lock from a linked worktree admin dir", () => {
    const { workspace, admin } = makeLinkedWorktree();
    const lockPath = join(admin, "index.lock");
    writeFileSync(lockPath, "locked\n", "utf8");
    clearStaleWorktreeIndexLock(workspace);
    expect(existsSync(lockPath)).toBe(false);
  });

  it("should no-op for plain worktrees without linked layout", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-plain-"));
    roots.push(workspace);
    mkdirSync(join(workspace, ".git"));
    expect(() => clearStaleWorktreeIndexLock(workspace)).not.toThrow();
  });

  it("should no-op when .git is missing", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-nogit-"));
    roots.push(workspace);
    expect(() => clearStaleWorktreeIndexLock(workspace)).not.toThrow();
  });
});
