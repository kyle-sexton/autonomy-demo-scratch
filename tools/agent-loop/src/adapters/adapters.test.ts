import { describe, expect, it } from "vitest";

import type { IterationContext } from "../types.js";
import { selectAdapter } from "./index.js";

const NO_ADAPTER_RE = /No adapter for CLI/;
const METERED_KEY_RE = /ANTHROPIC_API_KEY|OPENAI_API_KEY|CODEX_API_KEY/;

const baseCtx: IterationContext = {
  containerImage: "agent-loop-cursor:thin",
  hostWorkspacePath: "/tmp/ws",
  containerWorkspacePath: "/workspace",
  prompt: "do the thing",
  iterationLabel: "iteration-01-cursor",
};

describe("selectAdapter", () => {
  it("should return adapters for all implemented CLIs", () => {
    expect(typeof selectAdapter("cursor")).toBe("function");
    expect(typeof selectAdapter("claude")).toBe("function");
    expect(typeof selectAdapter("codex")).toBe("function");
    expect(typeof selectAdapter("grok")).toBe("function");
  });

  it("should throw for an unimplemented CLI", () => {
    expect(() => selectAdapter("unknown" as "cursor")).toThrow(NO_ADAPTER_RE);
  });
});

describe("cursorAdapter", () => {
  it("should require the CURSOR_API_KEY env and mark itself credentialed", () => {
    const inv = selectAdapter("cursor")(baseCtx);
    expect(inv.requiredEnv).toEqual(["CURSOR_API_KEY"]);
    expect(inv.requiresCredential).toBe(true);
  });

  it("should NOT request any metered API-key env var (no silent metered fallback)", () => {
    const inv = selectAdapter("cursor")(baseCtx);
    for (const name of inv.requiredEnv) {
      expect(name).not.toMatch(METERED_KEY_RE);
    }
  });

  it("should build a headless invocation with the Tier-0 confirmed flags", () => {
    const inv = selectAdapter("cursor")(baseCtx);
    expect(inv.command[0]).toBe("cursor-agent");
    expect(inv.command).toContain("--print");
    expect(inv.command).toContain("--force");
    expect(inv.command).toContain("--trust");
    expect(inv.command).toContain("--workspace");
    expect(inv.command).toContain("/workspace");
    expect(inv.command.at(-1)).toBe("do the thing");
  });

  it("should include the model flag only when a model slug is provided", () => {
    const withModel = selectAdapter("cursor")({ ...baseCtx, resolvedModelSlug: "sonnet-4" });
    expect(withModel.command).toContain("--model");
    expect(withModel.command).toContain("sonnet-4");

    const withoutModel = selectAdapter("cursor")(baseCtx);
    expect(withoutModel.command).not.toContain("--model");
  });
});

describe("claudeAdapter", () => {
  it("should require CLAUDE_CODE_OAUTH_TOKEN and never ANTHROPIC_API_KEY", () => {
    const inv = selectAdapter("claude")({ ...baseCtx, iterationLabel: "iteration-01-claude" });
    expect(inv.requiredEnv).toEqual(["CLAUDE_CODE_OAUTH_TOKEN"]);
    for (const name of inv.requiredEnv) {
      expect(name).not.toMatch(METERED_KEY_RE);
    }
  });

  it("should build a fresh-context headless invocation with spend caps", () => {
    const inv = selectAdapter("claude")({ ...baseCtx, iterationLabel: "iteration-01-claude" });
    expect(inv.command.slice(0, 11)).toEqual([
      "claude",
      "-p",
      "--permission-mode",
      "bypassPermissions",
      "--no-session-persistence",
      "--output-format",
      "stream-json",
      "--max-turns",
      "40",
      "--max-budget-usd",
      "2",
    ]);
    expect(inv.command).not.toContain("--mode");
    expect(inv.command.at(-1)).toBe("do the thing");
  });

  it("should include the model flag only when a model slug is provided", () => {
    const withModel = selectAdapter("claude")({
      ...baseCtx,
      iterationLabel: "iteration-01-claude",
      resolvedModelSlug: "claude-sonnet-4-6",
    });
    expect(withModel.command).toContain("--model");
    expect(withModel.command).toContain("claude-sonnet-4-6");

    const withoutModel = selectAdapter("claude")({
      ...baseCtx,
      iterationLabel: "iteration-01-claude",
    });
    expect(withoutModel.command).not.toContain("--model");
  });

  it("should honor AGENT_LOOP_CLAUDE_PERMISSION_PROBE for operator matrix runs", () => {
    const probeEnv = "AGENT_LOOP_CLAUDE_PERMISSION_PROBE";
    const previous = process.env[probeEnv];
    process.env[probeEnv] = "dontAsk";
    try {
      const inv = selectAdapter("claude")({
        ...baseCtx,
        iterationLabel: "iteration-01-claude",
      });
      expect(inv.command).toContain("dontAsk");
    } finally {
      if (previous === undefined) {
        delete process.env[probeEnv];
      } else {
        process.env[probeEnv] = previous;
      }
    }
  });
});

describe("codexAdapter", () => {
  it("should use subscription auth via bind mount and never metered API env vars", () => {
    const inv = selectAdapter("codex")({ ...baseCtx, iterationLabel: "iteration-01-codex" });
    expect(inv.requiredEnv).toEqual([]);
    expect(inv.requiresCredential).toBe(true);
  });

  it("should build a headless codex exec invocation", () => {
    const inv = selectAdapter("codex")({
      ...baseCtx,
      iterationLabel: "iteration-01-codex",
      resolvedModelSlug: "gpt-5.3-codex",
    });
    expect(inv.command.slice(0, 8)).toEqual([
      "codex",
      "exec",
      "--json",
      "--full-auto",
      "--sandbox",
      "workspace-write",
      "--model",
      "gpt-5.3-codex",
    ]);
    expect(inv.command.at(-1)).toBe("do the thing");
  });
});

describe("grokAdapter", () => {
  it("should use subscription auth via bind mount and never metered API env vars", () => {
    const inv = selectAdapter("grok")({ ...baseCtx, iterationLabel: "iteration-01-grok" });
    expect(inv.requiredEnv).toEqual([]);
    expect(inv.requiresCredential).toBe(true);
  });

  it("should build a headless grok invocation", () => {
    const inv = selectAdapter("grok")({
      ...baseCtx,
      iterationLabel: "iteration-01-grok",
      resolvedModelSlug: "grok-build",
      outputFormat: "stream-json",
    });
    expect(inv.command.slice(0, 7)).toEqual([
      "grok",
      "--no-auto-update",
      "-p",
      "do the thing",
      "--always-approve",
      "--output-format",
      "streaming-json",
    ]);
    expect(inv.command.slice(7, 9)).toEqual(["--cwd", "/workspace"]);
    expect(inv.command).toContain("-m");
    expect(inv.command).toContain("grok-build");
  });

  it("should emit plain text output format when configured", () => {
    const inv = selectAdapter("grok")({
      ...baseCtx,
      iterationLabel: "iteration-01-grok",
      outputFormat: "text",
    });
    expect(inv.command).toContain("--output-format");
    expect(inv.command).toContain("text");
  });
});
