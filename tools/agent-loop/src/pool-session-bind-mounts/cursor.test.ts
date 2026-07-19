import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { CURSOR_AGENT_POOL } from "../agent-pool.js";
import {
  applyHeadlessContainerBoundaries,
  resolveClaudeSettingsHeadlessPath,
  resolveCursorHooksDisabledPath,
  resolveCursorPoolSessionBindMounts,
  stripHooksFromClaudeSettings,
} from "./cursor.js";

describe("stripHooksFromClaudeSettings", () => {
  it("should remove hooks key and preserve other settings", () => {
    const stripped = stripHooksFromClaudeSettings({
      env: { FOO: "bar" },
      hooks: { PreToolUse: [] },
      permissions: { allow: [] },
    });
    expect(stripped).toEqual({ env: { FOO: "bar" }, permissions: { allow: [] } });
    expect(stripped).not.toHaveProperty("hooks");
  });
});

describe("applyHeadlessContainerBoundaries", () => {
  it("should deny git config in container session settings", () => {
    const headless = applyHeadlessContainerBoundaries({
      hooks: { PreToolUse: [] },
      permissions: { allow: ["Bash(git status)"] },
    });
    expect(headless).not.toHaveProperty("hooks");
    const permissions = headless.permissions as { deny: string[] };
    expect(permissions.deny).toContain("Bash(git config *)");
    expect(permissions.deny).toContain("Bash(git config:*)");
  });
});

describe("resolveCursorPoolSessionBindMounts", () => {
  let workspaceRoot = "";
  let agentLoopRoot = "";

  afterEach(() => {
    workspaceRoot = "";
    agentLoopRoot = "";
  });

  it("should return suppression mounts when inContainerHooks is suppressed", () => {
    workspaceRoot = mkdtempSync(join(tmpdir(), "agent-loop-ws-"));
    agentLoopRoot = mkdtempSync(join(tmpdir(), "agent-loop-tool-"));
    mkdirSync(join(workspaceRoot, ".claude"), { recursive: true });
    writeFileSync(
      join(workspaceRoot, ".claude/settings.json"),
      JSON.stringify({ hooks: { PreToolUse: [] }, env: {} }),
    );

    const runId = "test-run-id";
    const mounts = resolveCursorPoolSessionBindMounts(CURSOR_AGENT_POOL, {
      workspaceRoot,
      agentLoopProjectRoot: agentLoopRoot,
      runId,
    });

    expect(mounts).toHaveLength(2);
    expect(mounts[0]?.containerPath).toBe("/workspace/.claude/settings.json");
    expect(mounts[1]?.containerPath).toBe("/workspace/.cursor/hooks.json");

    const settingsRaw = readFileSync(
      resolveClaudeSettingsHeadlessPath(agentLoopRoot, runId),
      "utf8",
    );
    expect(JSON.parse(settingsRaw)).not.toHaveProperty("hooks");

    const hooksRaw = readFileSync(resolveCursorHooksDisabledPath(agentLoopRoot, runId), "utf8");
    expect(JSON.parse(hooksRaw)).toEqual({ version: 1, hooks: {} });
  });

  it("should return empty mounts when inContainerHooks is not suppressed", () => {
    const mounts = resolveCursorPoolSessionBindMounts(
      { ...CURSOR_AGENT_POOL, inContainerHooks: "none" },
      { workspaceRoot: "/tmp/ws", agentLoopProjectRoot: "/tmp/tool", runId: "noop" },
    );
    expect(mounts).toEqual([]);
  });
});
