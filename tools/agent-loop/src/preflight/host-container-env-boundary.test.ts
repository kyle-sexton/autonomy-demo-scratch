import { describe, expect, it, vi } from "vitest";

import { assertHostContainerEnvBoundary } from "./host-container-env-boundary.js";

describe("assertHostContainerEnvBoundary", () => {
  it("should exit when host CLAUDE_PROJECT_DIR is /workspace", () => {
    const exit = vi.fn(() => {
      throw new Error("exit");
    });
    const error = vi.fn();
    expect(() =>
      assertHostContainerEnvBoundary({
        env: { CLAUDE_PROJECT_DIR: "/workspace" },
        ports: { console: { error }, exit: { exit } },
      }),
    ).toThrow("exit");
    expect(exit).toHaveBeenCalledWith(5);
    expect(error).toHaveBeenCalled();
  });

  it("should exit when host CLAUDE_PROJECT_DIR is MSYS pathconv form of container mount", () => {
    const exit = vi.fn(() => {
      throw new Error("exit");
    });
    expect(() =>
      assertHostContainerEnvBoundary({
        env: {
          MINGW_PREFIX: "C:/Program Files/Git",
          CLAUDE_PROJECT_DIR: "C:/Program Files/Git/workspace",
        },
        ports: { console: { error: vi.fn() }, exit: { exit } },
      }),
    ).toThrow("exit");
    expect(exit).toHaveBeenCalledWith(5);
  });

  it("should allow host CLAUDE_PROJECT_DIR when unset or a real host path", () => {
    const exit = vi.fn();
    assertHostContainerEnvBoundary({
      env: {},
      ports: { console: { error: vi.fn() }, exit: { exit } },
    });
    assertHostContainerEnvBoundary({
      env: { CLAUDE_PROJECT_DIR: "D:/dev/example-org/example-repo" },
      ports: { console: { error: vi.fn() }, exit: { exit } },
    });
    expect(exit).not.toHaveBeenCalled();
  });
});
