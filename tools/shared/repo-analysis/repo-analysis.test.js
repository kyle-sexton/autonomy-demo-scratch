import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, describe, expect, it } from "vitest";

import {
  countFiles,
  detectFrameworks,
  detectRepoStructure,
  parseGitHubUrl,
} from "./repo-analysis.js";

const tmpBase = join(tmpdir(), `repo-test-${Date.now()}`);

function createTempDir(...dirs) {
  const base = join(tmpBase, `test-${Math.random().toString(36).slice(2, 8)}`);
  mkdirSync(base, { recursive: true });
  for (const d of dirs) {
    mkdirSync(join(base, d), { recursive: true });
  }
  return base;
}

function createTempProject(files) {
  const base = createTempDir();
  for (const [path, content] of Object.entries(files)) {
    const fullPath = join(base, path);
    mkdirSync(join(fullPath, ".."), { recursive: true });
    writeFileSync(fullPath, content, "utf-8");
  }
  return base;
}

afterAll(() => rmSync(tmpBase, { recursive: true, force: true }));

describe("parseGitHubUrl", () => {
  it("should parse HTTPS URL", () => {
    const result = parseGitHubUrl("https://github.com/Dometrain/getting-started-mcp");
    expect(result).toEqual({ owner: "Dometrain", repo: "getting-started-mcp" });
  });

  it("should parse HTTPS URL with .git suffix", () => {
    const result = parseGitHubUrl("https://github.com/owner/repo.git");
    expect(result).toEqual({ owner: "owner", repo: "repo" });
  });

  it("should parse SSH URL", () => {
    const result = parseGitHubUrl("git@github.com:owner/repo.git");
    expect(result).toEqual({ owner: "owner", repo: "repo" });
  });

  it("should parse repo names containing dots", () => {
    expect(parseGitHubUrl("https://github.com/vercel/next.js")).toEqual({
      owner: "vercel",
      repo: "next.js",
    });
    expect(parseGitHubUrl("https://github.com/socketio/socket.io.git")).toEqual({
      owner: "socketio",
      repo: "socket.io",
    });
  });

  it("should return null for non-GitHub URL", () => {
    expect(parseGitHubUrl("https://gitlab.com/owner/repo")).toBeNull();
  });

  it("should return null for empty input", () => {
    expect(parseGitHubUrl(null)).toBeNull();
    expect(parseGitHubUrl("")).toBeNull();
  });
});

describe("detectRepoStructure", () => {
  it("should detect per-section structure with numbered folders", () => {
    const dir = createTempDir("01-intro", "02-basics", "03-advanced");
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("per-section");
    expect(result.sections).toHaveLength(3);
    expect(result.sections[0].name).toBe("01-intro");
  });

  it("should detect start/end subdirs in sections", () => {
    const dir = createTempDir("01-intro/start", "01-intro/end", "02-basics/start", "02-basics/end");
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("per-section");
    expect(result.sections[0].hasStart).toBe(true);
    expect(result.sections[0].hasEnd).toBe(true);
  });

  it("should detect single-state when no numbered folders", () => {
    const dir = createTempDir("src", "tests", "docs");
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("single-state");
  });

  it("should detect single-state with only one numbered folder", () => {
    const dir = createTempDir("01-only", "src");
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("single-state");
  });

  it("should detect section-NN pattern (Dometrain primary)", () => {
    const dir = createTempDir("section-03", "section-04", "section-05");
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("per-section");
    expect(result.sections).toHaveLength(3);
    expect(result.sections[0].name).toBe("section-03");
  });

  it("should detect section-NN with start/end subdirs", () => {
    const dir = createTempDir(
      "section-03/start",
      "section-03/end",
      "section-04/start",
      "section-04/end",
    );
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("per-section");
    expect(result.sections[0].hasStart).toBe(true);
    expect(result.sections[0].hasEnd).toBe(true);
  });

  it("should detect chapter-NN pattern", () => {
    const dir = createTempDir("chapter-01", "chapter-02", "chapter-03");
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("per-section");
    expect(result.sections).toHaveLength(3);
  });

  it("should detect N. Title pattern (Dometrain alternate)", () => {
    const dir = createTempDir("2. Async Await", "4. Creating Task", "5. Best Practices");
    const result = detectRepoStructure(dir);
    expect(result.type).toBe("per-section");
    expect(result.sections).toHaveLength(3);
  });
});

describe("detectFrameworks", () => {
  it("should detect Node.js project", () => {
    const dir = createTempProject({
      "package.json": '{"name": "test-app", "dependencies": {"express": "^4.0"}}',
    });
    const results = detectFrameworks(dir);
    expect(results).toHaveLength(1);
    expect(results[0].framework).toBe("node");
    expect(results[0].details.name).toBe("test-app");
    expect(results[0].details.depCount).toBe(1);
  });

  it("should detect .NET project", () => {
    const dir = createTempProject({ "MyApp.csproj": "<Project />" });
    const results = detectFrameworks(dir);
    expect(results.some((r) => r.framework === "dotnet")).toBe(true);
  });

  it("should detect multiple frameworks in subdirectories", () => {
    const dir = createTempProject({
      "frontend/package.json": '{"name": "frontend"}',
      "backend/MyApi.csproj": "<Project />",
    });
    const results = detectFrameworks(dir);
    expect(results.length).toBeGreaterThanOrEqual(2);
  });
});

describe("countFiles", () => {
  it("should count files by extension", () => {
    const dir = createTempDir("src");
    writeFileSync(join(dir, "src", "app.ts"), "", "utf-8");
    writeFileSync(join(dir, "src", "utils.ts"), "", "utf-8");
    writeFileSync(join(dir, "README.md"), "", "utf-8");

    const result = countFiles(dir);
    expect(result.total).toBe(3);
    expect(result.byExtension[".ts"]).toBe(2);
    expect(result.byExtension[".md"]).toBe(1);
  });
});
