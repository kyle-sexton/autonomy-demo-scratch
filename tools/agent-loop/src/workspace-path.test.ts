import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  assertNoPathTraversal,
  assertPathUnderRoot,
  resolvePathUnderRoot,
  WorkspacePathError,
} from "./workspace-path.js";

describe("assertNoPathTraversal", () => {
  it("should reject .. segments", () => {
    expect(() => assertNoPathTraversal("../../outside")).toThrow(WorkspacePathError);
  });

  it("should allow normal relative paths", () => {
    expect(() => assertNoPathTraversal(".work/foo/out/phase-1.done")).not.toThrow();
  });
});

describe("resolvePathUnderRoot", () => {
  it("should resolve paths inside workspace root", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-path-"));
    const nested = join(root, "scripts");
    mkdirSync(nested, { recursive: true });
    const resolved = resolvePathUnderRoot({
      workspaceRoot: root,
      relativePath: "scripts/verify.sh",
    });
    expect(resolved).toBe(resolve(root, "scripts/verify.sh"));
  });

  it("should reject paths that escape workspace root", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-path-escape-"));
    expect(() =>
      resolvePathUnderRoot({ workspaceRoot: root, relativePath: "../../outside" }),
    ).toThrow(WorkspacePathError);
  });

  it("should reject absolute paths outside workspace root", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-path-abs-"));
    expect(() =>
      resolvePathUnderRoot({ workspaceRoot: root, relativePath: resolve(tmpdir(), "outside") }),
    ).toThrow(WorkspacePathError);
  });
});

describe("assertPathUnderRoot", () => {
  it("should return normalized path when under root", () => {
    const root = resolve("/tmp/workspace");
    expect(assertPathUnderRoot("/tmp/workspace/out/file", root)).toBe(
      resolve("/tmp/workspace/out/file"),
    );
  });
});
