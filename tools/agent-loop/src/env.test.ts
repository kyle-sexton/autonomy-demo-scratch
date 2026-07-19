import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  applyEnvAssignments,
  credentialSetupHint,
  ENV_FILENAME,
  loadProjectEnv,
  missingEnvVars,
  parseEnvAssignments,
} from "./env.js";

describe("parseEnvAssignments", () => {
  it("should parse KEY=VALUE pairs and skip blanks and comments", () => {
    expect(
      parseEnvAssignments(`
# comment
CURSOR_API_KEY=crsr_abc

OTHER="quoted"
`),
    ).toEqual([
      { key: "CURSOR_API_KEY", value: "crsr_abc" },
      { key: "OTHER", value: "quoted" },
    ]);
  });

  it("should strip single-quoted values", () => {
    expect(parseEnvAssignments("TOKEN='abc'")).toEqual([{ key: "TOKEN", value: "abc" }]);
  });

  it("should ignore lines without an equals sign", () => {
    expect(parseEnvAssignments("NOT_A_VAR\nKEY=ok")).toEqual([{ key: "KEY", value: "ok" }]);
  });
});

describe("applyEnvAssignments", () => {
  it("should set keys that are absent", () => {
    const env: NodeJS.ProcessEnv = {};
    expect(applyEnvAssignments([{ key: "A", value: "1" }], env)).toEqual(["A"]);
    expect(env.A).toBe("1");
  });

  it("should not override a non-empty existing value", () => {
    const env: NodeJS.ProcessEnv = { CURSOR_API_KEY: "from-os" };
    expect(applyEnvAssignments([{ key: "CURSOR_API_KEY", value: "from-file" }], env)).toEqual([]);
    expect(env.CURSOR_API_KEY).toBe("from-os");
  });

  it("should fill in when the existing value is an empty string", () => {
    const env: NodeJS.ProcessEnv = { CURSOR_API_KEY: "" };
    expect(applyEnvAssignments([{ key: "CURSOR_API_KEY", value: "from-file" }], env)).toEqual([
      "CURSOR_API_KEY",
    ]);
    expect(env.CURSOR_API_KEY).toBe("from-file");
  });
});

describe("loadProjectEnv", () => {
  it("should load .env from the project root", () => {
    const dir = mkdtempSync(join(tmpdir(), "ralph-env-dotenv-"));
    writeFileSync(join(dir, ENV_FILENAME), "CURSOR_API_KEY=crsr_file\n", "utf8");

    const env: NodeJS.ProcessEnv = {};
    expect(loadProjectEnv(dir, env)).toEqual(["CURSOR_API_KEY"]);
    expect(env.CURSOR_API_KEY).toBe("crsr_file");
  });

  it("should not override a non-empty OS env value", () => {
    const dir = mkdtempSync(join(tmpdir(), "ralph-env-"));
    writeFileSync(join(dir, ENV_FILENAME), "CURSOR_API_KEY=crsr_file\nFROM_FILE=1\n", "utf8");

    const env: NodeJS.ProcessEnv = { CURSOR_API_KEY: "crsr_os" };
    expect(loadProjectEnv(dir, env)).toEqual(["FROM_FILE"]);
    expect(env.CURSOR_API_KEY).toBe("crsr_os");
    expect(env.FROM_FILE).toBe("1");
  });

  it("should return empty when .env is absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "ralph-env-missing-"));
    const env: NodeJS.ProcessEnv = {};
    expect(loadProjectEnv(dir, env)).toEqual([]);
  });
});

describe("missingEnvVars", () => {
  it("should return empty when every required var is present and non-empty", () => {
    expect(missingEnvVars(["CURSOR_API_KEY"], { CURSOR_API_KEY: "abc" })).toEqual([]);
  });

  it("should report a var that is entirely absent", () => {
    expect(missingEnvVars(["CURSOR_API_KEY"], {})).toEqual(["CURSOR_API_KEY"]);
  });

  it("should treat an empty-string value as missing", () => {
    expect(missingEnvVars(["CURSOR_API_KEY"], { CURSOR_API_KEY: "" })).toEqual(["CURSOR_API_KEY"]);
  });

  it("should report every missing var when several are required", () => {
    expect(missingEnvVars(["A", "B", "C"], { B: "set" })).toEqual(["A", "C"]);
  });

  it("should return empty for an empty requirement list", () => {
    expect(missingEnvVars([], {})).toEqual([]);
  });
});

describe("credentialSetupHint", () => {
  it("should name missing vars and point at .env.example and README", () => {
    const hint = credentialSetupHint("/proj", ["CURSOR_API_KEY"]);
    expect(hint).toContain("CURSOR_API_KEY");
    expect(hint).toContain(".env.example");
    expect(hint).toContain("First-time setup");
  });
});
