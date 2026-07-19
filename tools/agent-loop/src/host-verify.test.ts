import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { runHostVerifyScript, tailLines } from "./host-verify.js";

describe("tailLines", () => {
  it("should return original text when line count is within max", () => {
    expect(tailLines("a\nb\nc", 3)).toBe("a\nb\nc");
    expect(tailLines("a\nb", 5)).toBe("a\nb");
  });

  it("should return only the last maxLines lines", () => {
    expect(tailLines("a\nb\nc\nd", 2)).toBe("c\nd");
  });
});

describe("runHostVerifyScript", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function makeWorkspace(scriptBody: string): string {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-host-verify-"));
    roots.push(root);
    mkdirSync(join(root, "scripts"), { recursive: true });
    writeFileSync(join(root, "scripts", "verify.sh"), scriptBody, "utf8");
    return root;
  }

  it("should report passed when script exits 0", () => {
    const workspace = makeWorkspace("#!/usr/bin/env bash\nexit 0\n");
    const result = runHostVerifyScript(workspace, "scripts/verify.sh");
    expect(result.passed).toBe(true);
    expect(result.exitCode).toBe(0);
  });

  it("should report failure when script exits non-zero", () => {
    const workspace = makeWorkspace("#!/usr/bin/env bash\nexit 2\n");
    const result = runHostVerifyScript(workspace, "scripts/verify.sh");
    expect(result.passed).toBe(false);
    expect(result.exitCode).toBe(2);
  });

  it("should reject scripts outside workspace without executing bash", () => {
    const workspace = mkdtempSync(join(tmpdir(), "agent-loop-host-verify-escape-"));
    roots.push(workspace);
    const result = runHostVerifyScript(workspace, "../../outside/evil.sh");
    expect(result.passed).toBe(false);
    expect(result.stderr).toContain("..");
  });
});
