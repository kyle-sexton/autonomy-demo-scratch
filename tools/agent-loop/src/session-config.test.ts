import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { normalizeHostFilesystemPath } from "./host-path.js";
import { resolvePromptPath, resolveWorkspacePath } from "./session-config.js";

describe("resolveWorkspacePath", () => {
  it("should use default when unset", () => {
    expect(resolveWorkspacePath(undefined, "/cwd", "/default")).toBe("/default");
  });

  it("should resolve relative paths from cwd", () => {
    expect(resolveWorkspacePath("wt/feature", "/repo/tools/agent-loop", "/default")).toBe(
      normalizeHostFilesystemPath(resolve("/repo/tools/agent-loop/wt/feature")),
    );
  });

  it("should pass through absolute paths", () => {
    const abs = normalizeHostFilesystemPath(resolve("/other/repo/worktree"));
    expect(resolveWorkspacePath(abs, "/cwd", "/default")).toBe(abs);
  });
});

describe("resolvePromptPath", () => {
  it("should resolve relative prompt paths from project root", () => {
    expect(resolvePromptPath("examples/toy-backlog.prompt.md", "/tool")).toBe(
      normalizeHostFilesystemPath(resolve("/tool/examples/toy-backlog.prompt.md")),
    );
  });
});
