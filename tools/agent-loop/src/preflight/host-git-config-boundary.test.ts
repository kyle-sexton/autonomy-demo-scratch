import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { HOST_GIT_CONFIG_LEAK_EXIT_CODE } from "../constants.js";
import {
  auditHostGitConfig,
  hostGitConfigIsClean,
  repairHostGitConfigLeaks,
} from "../container-boundary.js";
import type { RunLoopPorts } from "../ports.js";
import {
  assertHostGitConfigBoundary,
  repairHostGitConfigBoundary,
} from "./host-git-config-boundary.js";

function makePorts(): { ports: RunLoopPorts; exit: ReturnType<typeof vi.fn> } {
  const exit = vi.fn();
  return {
    exit,
    ports: {
      console: { error: vi.fn(), log: vi.fn() },
      exit: { exit },
    } as unknown as RunLoopPorts,
  };
}

describe("host-git-config-boundary", () => {
  const roots: string[] = [];

  beforeEach(() => {
    // Isolate spawned git from ambient global/system config (e.g. actions/checkout
    // adds a global safe.directory=* on CI runners) so the audit sees only the
    // per-test repo-local config. spawnSync inherits these stubbed env vars.
    const home = mkdtempSync(join(tmpdir(), "agent-loop-git-home-"));
    roots.push(home);
    const emptyGlobalConfig = join(home, ".gitconfig");
    writeFileSync(emptyGlobalConfig, "");
    vi.stubEnv("HOME", home);
    vi.stubEnv("GIT_CONFIG_GLOBAL", emptyGlobalConfig);
    vi.stubEnv("GIT_CONFIG_SYSTEM", "");
    vi.stubEnv("GIT_CONFIG_NOSYSTEM", "1");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function initRepo(): string {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-git-boundary-"));
    roots.push(root);
    const init = spawnSync("git", ["init"], { cwd: root, encoding: "utf8" });
    expect(init.status).toBe(0);
    return root;
  }

  it("should repair core.worktree sentinel then pass assert", () => {
    const repo = initRepo();
    spawnSync("git", ["config", "core.worktree", "/workspace"], { cwd: repo });
    const logLines: string[] = [];
    const repairs = repairHostGitConfigBoundary({
      hostWorkspacePath: repo,
      env: {},
      logLine: (line) => {
        logLines.push(line);
      },
    });
    expect(repairs.some((r) => r.key === "core.worktree")).toBe(true);
    expect(hostGitConfigIsClean(repo, {})).toBe(true);

    const { ports, exit } = makePorts();
    assertHostGitConfigBoundary({
      hostWorkspacePath: repo,
      env: {},
      ports,
    });
    expect(exit).not.toHaveBeenCalled();
  });

  it("should exit 9 when worktree sentinel is present without repair", () => {
    const repo = initRepo();
    spawnSync("git", ["config", "core.worktree", "/workspace"], { cwd: repo });
    const { ports, exit } = makePorts();

    assertHostGitConfigBoundary({
      hostWorkspacePath: repo,
      env: {},
      ports,
    });

    expect(exit).toHaveBeenCalledWith(HOST_GIT_CONFIG_LEAK_EXIT_CODE);
  });

  it("should repair autocrlf true", () => {
    const repo = initRepo();
    spawnSync("git", ["config", "core.autocrlf", "true"], { cwd: repo });
    const repairs = repairHostGitConfigLeaks(repo, {});
    expect(repairs.some((r) => r.key === "core.autocrlf")).toBe(true);
    expect(auditHostGitConfig(repo, {}).find((v) => v.key === "core.autocrlf")).toBeUndefined();
  });

  it("should repair safe.directory star", () => {
    const repo = initRepo();
    spawnSync("git", ["config", "--add", "safe.directory", "*"], { cwd: repo });
    const repairs = repairHostGitConfigLeaks(repo, {});
    expect(repairs.some((r) => r.key === "safe.directory")).toBe(true);
  });
});
