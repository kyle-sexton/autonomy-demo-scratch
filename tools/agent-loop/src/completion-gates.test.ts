import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  countCompletionProgress,
  evaluateCompletionGates,
  inferBlockedFileFromCompletion,
  validateCompletionGatePaths,
} from "./completion-gates.js";
import { WorkspacePathError } from "./workspace-path.js";

describe("validateCompletionGatePaths", () => {
  it("should reject completion paths outside workspace", () => {
    const root = mkdtempSync(join(tmpdir(), "gate-validate-"));
    expect(() =>
      validateCompletionGatePaths({
        workspaceRoot: root,
        completionFile: "../../outside/.git/config",
      }),
    ).toThrow(WorkspacePathError);
  });
});

describe("inferBlockedFileFromCompletion", () => {
  it("should derive blocked path from done path", () => {
    expect(inferBlockedFileFromCompletion(".work/foo/out/phase-2.done")).toBe(
      ".work/foo/out/phase-2.blocked",
    );
  });
});

describe("evaluateCompletionGates", () => {
  it("should fail when blocked marker exists", () => {
    const root = mkdtempSync(join(tmpdir(), "gate-"));
    const out = join(root, ".work/foo/out");
    mkdirSync(out, { recursive: true });
    const blocked = join(out, "phase-1.blocked");
    writeFileSync(blocked, "blocked");
    const result = evaluateCompletionGates(
      {
        workspaceRoot: root,
        completionOutSubdir: ".work/foo/out",
        completionTarget: 1,
        completionFile: ".work/foo/out/phase-1.done",
        blockedFile: ".work/foo/out/phase-1.blocked",
        selfCheckFile: ".work/foo/out/phase-1.self-check.md",
      },
      0,
      0,
    );
    expect(result.fsComplete).toBe(false);
    expect(result.blockedPresent).toBe(true);
  });

  it("should require self-check and done file when configured", () => {
    const root = mkdtempSync(join(tmpdir(), "gate-"));
    const outDir = join(root, ".work/foo/out");
    mkdirSync(outDir, { recursive: true });
    const done = join(outDir, "phase-1.done");
    writeFileSync(done, "done", { flag: "w" });
    const withoutCheck = evaluateCompletionGates(
      {
        workspaceRoot: root,
        completionOutSubdir: ".work/foo/out",
        completionTarget: 1,
        completionFile: ".work/foo/out/phase-1.done",
        selfCheckFile: ".work/foo/out/phase-1.self-check.md",
      },
      0,
      1,
    );
    expect(withoutCheck.fsComplete).toBe(false);

    writeFileSync(join(outDir, "phase-1.self-check.md"), "ok");
    const withCheck = evaluateCompletionGates(
      {
        workspaceRoot: root,
        completionOutSubdir: ".work/foo/out",
        completionTarget: 1,
        completionFile: ".work/foo/out/phase-1.done",
        selfCheckFile: ".work/foo/out/phase-1.self-check.md",
      },
      0,
      1,
    );
    expect(withCheck.fsComplete).toBe(true);
  });

  it("should complete when only completion file is configured and present", () => {
    const root = mkdtempSync(join(tmpdir(), "gate-"));
    const outDir = join(root, ".work/foo/out");
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "phase-1.done"), "done");
    const result = evaluateCompletionGates(
      {
        workspaceRoot: root,
        completionOutSubdir: ".work/foo/out",
        completionTarget: 1,
        completionFile: ".work/foo/out/phase-1.done",
      },
      0,
      1,
    );
    expect(result.fsComplete).toBe(true);
    expect(result.selfCheckPresent).toBe(false);
    expect(result.reason).toContain("present");
  });

  it("should fall back to artifact count when completion file unset", () => {
    const root = mkdtempSync(join(tmpdir(), "gate-"));
    const out = join(root, "out");
    mkdirSync(out, { recursive: true });
    writeFileSync(join(out, "a.txt"), "x");
    expect(
      evaluateCompletionGates(
        { workspaceRoot: root, completionOutSubdir: "out", completionTarget: 1 },
        0,
        1,
      ).fsComplete,
    ).toBe(true);
  });
});

describe("countCompletionProgress", () => {
  it("should return 1 when completion file exists", () => {
    const root = mkdtempSync(join(tmpdir(), "prog-"));
    mkdirSync(join(root, "out"), { recursive: true });
    writeFileSync(join(root, "out", "phase-1.done"), "x");
    expect(
      countCompletionProgress({
        workspaceRoot: root,
        completionOutSubdir: "out",
        completionFile: "out/phase-1.done",
      }),
    ).toBe(1);
  });
});
