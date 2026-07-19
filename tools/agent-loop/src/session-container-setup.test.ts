import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  CLAUDE_AGENT_POOL,
  CODEX_AGENT_POOL,
  CURSOR_AGENT_POOL,
  GROK_AGENT_POOL,
} from "./agent-pool.js";
import { CODEX_HOME_CONTAINER } from "./codex-auth.js";
import { CONTAINER_WORKSPACE_MOUNT } from "./constants.js";
import { GROK_HOME_CONTAINER } from "./grok-auth.js";
import { resolveSessionContainerSetup } from "./session-container-setup.js";

const AGENT_LOOP_PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("resolveSessionContainerSetup", () => {
  it("should set CLAUDE_PROJECT_DIR in additionalContainerEnv at runtime", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-ws-"));
    mkdirSync(join(workspace, ".claude"), { recursive: true });
    writeFileSync(join(workspace, ".claude", "settings.json"), "{}\n", "utf8");
    writeFileSync(join(workspace, ".git"), "gitdir: nowhere\n", "utf8");

    const setup = resolveSessionContainerSetup({
      pool: CURSOR_AGENT_POOL,
      hostWorkspacePath: workspace,
      agentLoopProjectRoot: AGENT_LOOP_PROJECT_ROOT,
      runId: "test-run",
      credentialMounts: [],
    });

    expect(setup.additionalContainerEnv.CLAUDE_PROJECT_DIR).toBe(CONTAINER_WORKSPACE_MOUNT);
    expect(setup.additionalContainerEnv.GIT_CONFIG_NOSYSTEM).toBe("1");
    expect(setup.additionalContainerEnv.GIT_CONFIG_COUNT).toBe("2");
    expect(setup.additionalContainerEnv.GIT_CONFIG_KEY_0).toBe("core.fileMode");
    expect(setup.additionalContainerEnv.GIT_CONFIG_VALUE_0).toBe("false");
    expect(setup.additionalContainerEnv.GIT_CONFIG_KEY_1).toBe("core.autocrlf");
    expect(setup.additionalContainerEnv.GIT_CONFIG_VALUE_1).toBe("false");
  });

  it("should set CLAUDE_PROJECT_DIR for claude-default pool runs", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-claude-ws-"));
    mkdirSync(join(workspace, ".claude"), { recursive: true });
    writeFileSync(join(workspace, ".claude", "settings.json"), "{}\n", "utf8");
    writeFileSync(join(workspace, ".git"), "gitdir: nowhere\n", "utf8");

    const setup = resolveSessionContainerSetup({
      pool: CLAUDE_AGENT_POOL,
      hostWorkspacePath: workspace,
      agentLoopProjectRoot: AGENT_LOOP_PROJECT_ROOT,
      runId: "test-claude-run",
      credentialMounts: [],
    });

    expect(setup.additionalContainerEnv.CLAUDE_PROJECT_DIR).toBe(CONTAINER_WORKSPACE_MOUNT);
  });

  it("should set HOME and GROK_HOME for grok pool runs", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-grok-ws-"));
    writeFileSync(join(workspace, ".git"), "gitdir: nowhere\n", "utf8");

    const setup = resolveSessionContainerSetup({
      pool: GROK_AGENT_POOL,
      hostWorkspacePath: workspace,
      agentLoopProjectRoot: AGENT_LOOP_PROJECT_ROOT,
      runId: "test-grok-run",
      credentialMounts: [],
    });

    expect(setup.additionalContainerEnv.HOME).toBe(CONTAINER_WORKSPACE_MOUNT);
    expect(setup.additionalContainerEnv.GROK_HOME).toBe(GROK_HOME_CONTAINER);
  });

  it("should set HOME and CODEX_HOME for codex pool runs", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-codex-ws-"));
    writeFileSync(join(workspace, ".git"), "gitdir: nowhere\n", "utf8");

    const setup = resolveSessionContainerSetup({
      pool: CODEX_AGENT_POOL,
      hostWorkspacePath: workspace,
      agentLoopProjectRoot: AGENT_LOOP_PROJECT_ROOT,
      runId: "test-codex-run",
      credentialMounts: [],
    });

    expect(setup.additionalContainerEnv.HOME).toBe(CONTAINER_WORKSPACE_MOUNT);
    expect(setup.additionalContainerEnv.CODEX_HOME).toBe(CODEX_HOME_CONTAINER);
  });
});
