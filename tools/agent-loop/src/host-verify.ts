import { spawnSync } from "node:child_process";

import { resolveRepoRelativePath } from "./workspace-snapshot.js";

export interface HostVerifyResult {
  readonly scriptPath: string;
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
  readonly passed: boolean;
}

export function runHostVerifyScript(
  workspaceRoot: string,
  scriptRelativeOrAbsolute: string,
): HostVerifyResult {
  let scriptPath: string;
  try {
    scriptPath = resolveRepoRelativePath({
      workspaceRoot,
      relativePath: scriptRelativeOrAbsolute,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      scriptPath: scriptRelativeOrAbsolute,
      exitCode: 1,
      stdout: "",
      stderr: message,
      passed: false,
    };
  }
  const result = spawnSync("bash", [scriptPath], {
    cwd: workspaceRoot,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
    shell: false,
  });
  const exitCode = result.status ?? 1;
  return {
    scriptPath,
    exitCode,
    stdout: result.stdout?.trimEnd() ?? "",
    stderr: result.stderr?.trimEnd() ?? "",
    passed: exitCode === 0,
  };
}

export function tailLines(text: string, maxLines: number): string {
  const lines = text.split("\n");
  if (lines.length <= maxLines) {
    return text;
  }
  return lines.slice(-maxLines).join("\n");
}
