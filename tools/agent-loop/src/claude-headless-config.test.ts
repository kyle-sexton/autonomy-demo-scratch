import { describe, expect, it } from "vitest";

import {
  CLAUDE_METERED_ENV,
  CLAUDE_OAUTH_ENV,
  CLAUDE_PERMISSION_PROBE_ENV,
  claudeMeteredOverrideMessage,
  claudeOAuthTokenMessage,
  resolveClaudeContainerRunUser,
  resolveClaudeHeadlessPermissionMode,
  validateClaudeSubscriptionAuth,
} from "./claude-headless-config.js";

describe("claude subscription auth boundary", () => {
  it("should accept OAuth token without metered key", () => {
    const env = { [CLAUDE_OAUTH_ENV]: "oauth-token" };
    expect(validateClaudeSubscriptionAuth(env)).toBeUndefined();
    expect(claudeOAuthTokenMessage(env)).toBeUndefined();
    expect(claudeMeteredOverrideMessage(env)).toBeUndefined();
  });

  it("should reject missing OAuth token", () => {
    expect(claudeOAuthTokenMessage({})).toContain(CLAUDE_OAUTH_ENV);
  });

  it("should reject metered key override", () => {
    const env = {
      [CLAUDE_OAUTH_ENV]: "oauth-token",
      [CLAUDE_METERED_ENV]: "sk-ant-api",
    };
    expect(claudeMeteredOverrideMessage(env)).toContain(CLAUDE_METERED_ENV);
    expect(validateClaudeSubscriptionAuth(env)).toContain(CLAUDE_METERED_ENV);
  });
});

describe("resolveClaudeHeadlessPermissionMode", () => {
  it("should default to bypassPermissions", () => {
    expect(resolveClaudeHeadlessPermissionMode({})).toBe("bypassPermissions");
  });

  it("should honor operator probe env for allowed modes", () => {
    expect(
      resolveClaudeHeadlessPermissionMode({
        [CLAUDE_PERMISSION_PROBE_ENV]: "dontAsk",
      }),
    ).toBe("dontAsk");
  });

  it("should ignore unknown probe values", () => {
    expect(
      resolveClaudeHeadlessPermissionMode({
        [CLAUDE_PERMISSION_PROBE_ENV]: "plan",
      }),
    ).toBe("bypassPermissions");
  });
});

describe("resolveClaudeContainerRunUser", () => {
  it("should default to 1000:1000 on Windows when env is unset", () => {
    expect(resolveClaudeContainerRunUser("/tmp/ws", "win32")).toBe("1000:1000");
  });

  it("should prefer AGENT_LOOP_UID and AGENT_LOOP_GID from the environment", () => {
    process.env["AGENT_LOOP_UID"] = "1001";
    process.env["AGENT_LOOP_GID"] = "1002";
    try {
      expect(resolveClaudeContainerRunUser("/tmp/ws", "win32")).toBe("1001:1002");
    } finally {
      process.env["AGENT_LOOP_UID"] = undefined;
      process.env["AGENT_LOOP_GID"] = undefined;
    }
  });
});
