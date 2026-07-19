import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { resolveBareHostPathFromAdminDir, resolveWorkspaceGitBridge } from "./resolve.js";
import { CONTAINER_BARE_GIT_MOUNT } from "./types.js";

describe("resolveBareHostPathFromAdminDir", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("should resolve commondir relative to admin dir", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-bare-"));
    roots.push(root);
    const bare = join(root, ".bare");
    const admin = join(bare, "worktrees", "wt1");
    mkdirSync(admin, { recursive: true });
    writeFileSync(join(admin, "commondir"), "../..\n", "utf8");
    expect(resolveBareHostPathFromAdminDir(admin)).toBe(bare);
  });
});

describe("resolveWorkspaceGitBridge", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function makeLinkedWorktree(): { workspace: string; bare: string; admin: string } {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-linked-"));
    roots.push(root);
    const bare = join(root, ".bare");
    const admin = join(bare, "worktrees", "slice");
    const workspace = join(root, "slice");
    mkdirSync(admin, { recursive: true });
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(admin, "commondir"), "../..\n", "utf8");
    writeFileSync(join(workspace, ".git"), `gitdir: ${admin.replace(/\\/gu, "/")}\n`, "utf8");
    return { workspace, bare, admin };
  }

  it("should return unavailable for missing .git", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-none-"));
    roots.push(workspace);
    const bridge = resolveWorkspaceGitBridge({
      hostWorkspacePath: workspace,
      containerWorkspacePath: "/workspace",
    });
    expect(bridge.mode).toBe("unavailable");
    expect(bridge.bindMounts).toHaveLength(0);
  });

  it("should return plain read-write without extra mounts", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-plain-"));
    roots.push(workspace);
    mkdirSync(join(workspace, ".git"));
    const bridge = resolveWorkspaceGitBridge({
      hostWorkspacePath: workspace,
      containerWorkspacePath: "/workspace",
    });
    expect(bridge.layout).toBe("plain");
    expect(bridge.mode).toBe("read-write");
    expect(bridge.bindMounts).toHaveLength(0);
  });

  it("should mount bare hub and set GIT_DIR for linked worktree", () => {
    const { workspace, bare, admin } = makeLinkedWorktree();
    const bridge = resolveWorkspaceGitBridge({
      hostWorkspacePath: workspace,
      containerWorkspacePath: "/workspace",
      gitBridgePolicy: "auto",
    });
    expect(bridge.layout).toBe("linked");
    expect(bridge.mode).toBe("read-write");
    expect(bridge.bindMounts).toEqual([
      { hostPath: bare, containerPath: CONTAINER_BARE_GIT_MOUNT },
    ]);
    expect(bridge.containerEnv.GIT_DIR).toBe(`${CONTAINER_BARE_GIT_MOUNT}/worktrees/slice`);
    expect(bridge.containerEnv.GIT_WORK_TREE).toBe("/workspace");
    expect(bridge.containerEnv.GIT_COMMON_DIR).toBe(CONTAINER_BARE_GIT_MOUNT);
    expect(bridge.containerEnv.GIT_CONFIG_COUNT).toBeUndefined();
    expect(admin).toContain("worktrees");
  });

  it("should use read-only bare mount when policy is read", () => {
    const { workspace, bare } = makeLinkedWorktree();
    const bridge = resolveWorkspaceGitBridge({
      hostWorkspacePath: workspace,
      containerWorkspacePath: "/workspace",
      gitBridgePolicy: "read",
    });
    expect(bridge.mode).toBe("read");
    expect(bridge.bindMounts).toEqual([
      { hostPath: bare, containerPath: CONTAINER_BARE_GIT_MOUNT, readOnly: true },
    ]);
  });

  it("should resolve relative gitdir pointers", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-rel-"));
    roots.push(root);
    const bare = join(root, ".bare");
    const admin = join(bare, "worktrees", "rel");
    const workspace = join(root, "checkout");
    mkdirSync(admin, { recursive: true });
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(admin, "commondir"), "../..\n", "utf8");
    const relativeAdmin = join("..", ".bare", "worktrees", "rel");
    writeFileSync(join(workspace, ".git"), `gitdir: ${relativeAdmin}\n`, "utf8");
    const bridge = resolveWorkspaceGitBridge({
      hostWorkspacePath: workspace,
      containerWorkspacePath: "/workspace",
    });
    expect(bridge.mode).toBe("read-write");
    expect(bridge.containerEnv.GIT_DIR).toBe(`${CONTAINER_BARE_GIT_MOUNT}/worktrees/rel`);
  });
});
