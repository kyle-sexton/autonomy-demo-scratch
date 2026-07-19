import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import {
  auditHostGitConfig,
  containerWorkspaceSentinels,
  hostRequiresCoreFilemodeFalse,
  isContainerWorkspaceSentinel,
  readHostCoreFilemode,
  readHostCoreWorktree,
  repairHostCoreFilemodeLeak,
  repairHostCoreWorktreeLeak,
  repairHostGitConfigLeaks,
} from "./container-boundary.js";

// Isolate git config from the host/CI environment for the whole file. The audit/repair
// functions read all-scope config (`git config --get-all` sees system + global + local),
// and CI's actions/checkout injects a global `safe.directory` entry — which would leak into
// a freshly-init'd test repo and make the "clean repo" assertions see a phantom violation.
// Point global config at an empty file and disable system config so only per-test local
// config is visible.
let gitIsolationRoot: string;
let savedGitConfigGlobal: string | undefined;
let savedGitConfigNoSystem: string | undefined;

beforeAll(() => {
  gitIsolationRoot = mkdtempSync(join(tmpdir(), "agent-loop-gitiso-"));
  const emptyGlobalConfig = join(gitIsolationRoot, "gitconfig");
  writeFileSync(emptyGlobalConfig, "");
  savedGitConfigGlobal = process.env["GIT_CONFIG_GLOBAL"];
  savedGitConfigNoSystem = process.env["GIT_CONFIG_NOSYSTEM"];
  process.env["GIT_CONFIG_GLOBAL"] = emptyGlobalConfig;
  process.env["GIT_CONFIG_NOSYSTEM"] = "1";
});

afterAll(() => {
  restoreEnv("GIT_CONFIG_GLOBAL", savedGitConfigGlobal);
  restoreEnv("GIT_CONFIG_NOSYSTEM", savedGitConfigNoSystem);
  rmSync(gitIsolationRoot, { recursive: true, force: true });
});

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}

describe("containerWorkspaceSentinels", () => {
  it("should always include /workspace", () => {
    const sentinels = containerWorkspaceSentinels({});
    expect(sentinels).toContain("/workspace");
    if (process.platform === "win32") {
      expect(sentinels).toContain("C:/Program Files/Git/workspace");
    } else {
      expect(sentinels).toEqual(["/workspace"]);
    }
  });

  it("should include MINGW_PREFIX/workspace when set", () => {
    const sentinels = containerWorkspaceSentinels({ MINGW_PREFIX: "C:/Program Files/Git" });
    expect(sentinels).toContain("/workspace");
    expect(sentinels).toContain("C:/Program Files/Git/workspace");
  });

  it("should include Git for Windows install workspace path on win32", () => {
    if (process.platform !== "win32") {
      return;
    }
    const sentinels = containerWorkspaceSentinels({ MINGW_PREFIX: "/mingw64" });
    expect(sentinels).toContain("/workspace");
    expect(sentinels).toContain("/mingw64/workspace");
    expect(sentinels).toContain("C:/Program Files/Git/workspace");
  });
});

describe("isContainerWorkspaceSentinel", () => {
  const env = { MINGW_PREFIX: "C:/Program Files/Git" };

  it("should match POSIX container mount", () => {
    expect(isContainerWorkspaceSentinel("/workspace", env)).toBe(true);
  });

  it("should match MSYS pathconv form derived from MINGW_PREFIX", () => {
    expect(isContainerWorkspaceSentinel("C:/Program Files/Git/workspace", env)).toBe(true);
  });

  it("should match Git for Windows stored form when MINGW_PREFIX is /mingw64", () => {
    if (process.platform !== "win32") {
      return;
    }
    expect(
      isContainerWorkspaceSentinel("C:/Program Files/Git/workspace", {
        MINGW_PREFIX: "/mingw64",
      }),
    ).toBe(true);
  });

  it("should not match host worktree paths", () => {
    expect(isContainerWorkspaceSentinel("D:/dev/example-org/example-repo", env)).toBe(false);
  });
});

describe("repairHostCoreFilemodeLeak", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function initRepo(): string {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-filemode-"));
    roots.push(root);
    const init = spawnSync("git", ["init"], { cwd: root, encoding: "utf8" });
    expect(init.status).toBe(0);
    return root;
  }

  it("should no-op on non-Windows hosts", () => {
    const repo = initRepo();
    const platform = process.platform;
    if (platform === "win32") {
      return;
    }
    spawnSync("git", ["config", "core.filemode", "true"], { cwd: repo });
    expect(repairHostCoreFilemodeLeak(repo)).toBe(false);
    expect(readHostCoreFilemode(repo)).toBe("true");
  });

  it("should pin core.filemode false on Windows when container git flipped it", () => {
    if (!hostRequiresCoreFilemodeFalse()) {
      return;
    }
    const repo = initRepo();
    spawnSync("git", ["config", "core.filemode", "true"], { cwd: repo });
    expect(repairHostCoreFilemodeLeak(repo)).toBe(true);
    expect(readHostCoreFilemode(repo)).toBe("false");
    expect(repairHostCoreFilemodeLeak(repo)).toBe(false);
  });
});

describe("repairHostCoreWorktreeLeak", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function initRepo(): string {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-worktree-"));
    roots.push(root);
    spawnSync("git", ["init"], { cwd: root, encoding: "utf8" });
    return root;
  }

  it("should unset core.worktree when value is container sentinel", () => {
    const repo = initRepo();
    spawnSync("git", ["config", "core.worktree", "/workspace"], { cwd: repo });
    expect(repairHostCoreWorktreeLeak(repo, {})).toBe(true);
    expect(readHostCoreWorktree(repo)).toBeUndefined();
  });
});

describe("repairHostGitConfigLeaks", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("should leave clean repo unchanged", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-clean-"));
    roots.push(root);
    spawnSync("git", ["init"], { cwd: root, encoding: "utf8" });
    if (hostRequiresCoreFilemodeFalse()) {
      spawnSync("git", ["config", "core.filemode", "false"], { cwd: root });
    }
    expect(repairHostGitConfigLeaks(root, {})).toEqual([]);
    expect(auditHostGitConfig(root, {})).toEqual([]);
  });
});
