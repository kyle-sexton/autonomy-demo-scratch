import { describe, expect, it, vi } from "vitest";

import { CLAUDE_AGENT_POOL } from "../agent-pool.js";
import { CLAUDE_METERED_ENV, CLAUDE_OAUTH_ENV } from "../claude-headless-config.js";
import type { RunLoopPorts } from "../ports.js";
import type { IterationContext } from "../types.js";
import { assertCredentialsPresent } from "./credentials.js";

const preflightContext: IterationContext = {
  containerImage: CLAUDE_AGENT_POOL.containerImage,
  hostWorkspacePath: "/ws",
  containerWorkspacePath: "/workspace",
  prompt: "probe",
  iterationLabel: "preflight",
};

function makePorts(): { ports: RunLoopPorts; exitCode: () => number | undefined } {
  let code: number | undefined;
  const ports: RunLoopPorts = {
    console: { error: vi.fn(), log: vi.fn(), warn: vi.fn() },
    exit: {
      exit: (c: number) => {
        code = c;
      },
    },
  };
  return { ports, exitCode: () => code };
}

describe("assertCredentialsPresent", () => {
  it("should refuse Claude pool when ANTHROPIC_API_KEY is set", () => {
    const { ports, exitCode } = makePorts();
    assertCredentialsPresent({
      pool: CLAUDE_AGENT_POOL,
      preflightContext,
      env: {
        [CLAUDE_OAUTH_ENV]: "oauth-token",
        [CLAUDE_METERED_ENV]: "sk-ant-api",
      },
      projectRoot: "/tool",
      ports,
    });
    expect(exitCode()).toBe(5);
  });

  it("should pass Claude pool when only OAuth token is set", () => {
    const { ports, exitCode } = makePorts();
    assertCredentialsPresent({
      pool: CLAUDE_AGENT_POOL,
      preflightContext,
      env: { [CLAUDE_OAUTH_ENV]: "oauth-token" },
      projectRoot: "/tool",
      ports,
    });
    expect(exitCode()).toBeUndefined();
  });
});
