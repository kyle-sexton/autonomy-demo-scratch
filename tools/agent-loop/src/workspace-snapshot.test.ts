import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { WorkspacePathError } from "./workspace-path.js";
import {
  detectRootJunk,
  diffSnapshots,
  type GitSnapshot,
  parseUntrackedAtRoot,
  resolveRepoRelativePath,
} from "./workspace-snapshot.js";

describe("resolveRepoRelativePath", () => {
  it("should resolve in-workspace relative paths", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-resolve-"));
    mkdirSync(join(root, "out"), { recursive: true });
    expect(resolveRepoRelativePath({ workspaceRoot: root, relativePath: "out/phase-1.done" })).toBe(
      resolve(root, "out/phase-1.done"),
    );
  });

  it("should reject traversal outside workspace", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-resolve-escape-"));
    expect(() =>
      resolveRepoRelativePath({ workspaceRoot: root, relativePath: "../../etc/passwd" }),
    ).toThrow(WorkspacePathError);
  });
});

describe("parseUntrackedAtRoot", () => {
  it("should list only root-level untracked paths", () => {
    const status = [
      "?? AppDataRoamingnvm",
      "?? tools/foo/bar",
      "?? README.md",
      " M AGENTS.md",
    ].join("\n");
    expect(parseUntrackedAtRoot(status)).toEqual(["AppDataRoamingnvm", "README.md"]);
  });
});

describe("detectRootJunk", () => {
  it("should flag unknown root files but not known manifests", () => {
    expect(detectRootJunk(["deployable", "README.md"])).toEqual(["deployable"]);
  });
});

describe("diffSnapshots", () => {
  it("should report new untracked root files", () => {
    const before: GitSnapshot = {
      statusShort: "",
      diffStat: "",
      untrackedAtRoot: [],
    };
    const after: GitSnapshot = {
      statusShort: "?? deployable",
      diffStat: "",
      untrackedAtRoot: ["deployable"],
    };
    const diff = diffSnapshots(before, after);
    expect(diff.newRootJunk).toEqual(["deployable"]);
  });
});
