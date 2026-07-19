import { join } from "node:path";

import { countCompletionArtifacts } from "./completion-artifacts.js";
import { fileExistsAt, resolveRepoRelativePath } from "./workspace-snapshot.js";

export interface CompletionGateConfig {
  readonly workspaceRoot: string;
  readonly completionOutSubdir: string;
  readonly completionTarget: number;
  /** Repo-relative path e.g. `.work/<slug>/out/phase-1.done` */
  readonly completionFile?: string;
  readonly blockedFile?: string;
  readonly selfCheckFile?: string;
}

export interface CompletionGateResult {
  readonly fsComplete: boolean;
  readonly progressed: boolean;
  readonly beforeCount: number;
  readonly afterCount: number;
  readonly blockedPresent: boolean;
  readonly selfCheckPresent: boolean;
  readonly completionFilePresent: boolean;
  readonly reason: string;
}

export function validateCompletionGatePaths(
  config: Pick<
    CompletionGateConfig,
    "workspaceRoot" | "completionFile" | "blockedFile" | "selfCheckFile"
  >,
): void {
  const workspace = { workspaceRoot: config.workspaceRoot };
  for (const relativePath of [config.completionFile, config.blockedFile, config.selfCheckFile]) {
    if (relativePath !== undefined && relativePath.trim() !== "") {
      resolveRepoRelativePath({ ...workspace, relativePath });
    }
  }
}

export function evaluateCompletionGates(
  config: CompletionGateConfig,
  beforeCount: number,
  afterCount: number,
): CompletionGateResult {
  const workspace = { workspaceRoot: config.workspaceRoot };
  const blockedPresent =
    config.blockedFile !== undefined &&
    fileExistsAt({ ...workspace, relativePath: config.blockedFile });
  const selfCheckPresent =
    config.selfCheckFile !== undefined &&
    fileExistsAt({ ...workspace, relativePath: config.selfCheckFile });
  const completionFilePresent =
    config.completionFile !== undefined &&
    fileExistsAt({ ...workspace, relativePath: config.completionFile });

  if (blockedPresent) {
    return {
      fsComplete: false,
      progressed: afterCount > beforeCount,
      beforeCount,
      afterCount,
      blockedPresent: true,
      selfCheckPresent,
      completionFilePresent,
      reason: `blocked marker present (${config.blockedFile})`,
    };
  }

  if (config.completionFile !== undefined) {
    const selfCheckRequired = config.selfCheckFile !== undefined;
    const fsComplete = completionFilePresent && (!selfCheckRequired || selfCheckPresent);
    let reason: string;
    if (!completionFilePresent && selfCheckRequired && !selfCheckPresent) {
      reason = `missing ${config.completionFile} and ${config.selfCheckFile}`;
    } else if (!completionFilePresent) {
      reason = `missing ${config.completionFile}`;
    } else if (selfCheckRequired && !selfCheckPresent) {
      reason = `missing ${config.selfCheckFile}`;
    } else if (selfCheckRequired) {
      reason = `${config.completionFile} and self-check present`;
    } else {
      reason = `${config.completionFile} present`;
    }
    return {
      fsComplete,
      progressed: afterCount > beforeCount,
      beforeCount,
      afterCount,
      blockedPresent: false,
      selfCheckPresent,
      completionFilePresent,
      reason,
    };
  }

  const fsComplete = afterCount >= config.completionTarget;
  return {
    fsComplete,
    progressed: afterCount > beforeCount,
    beforeCount,
    afterCount,
    blockedPresent: false,
    selfCheckPresent,
    completionFilePresent,
    reason: fsComplete
      ? `artifact count ${String(afterCount)}/${String(config.completionTarget)}`
      : `artifact count ${String(afterCount)}/${String(config.completionTarget)} incomplete`,
  };
}

export function countCompletionProgress(
  config: Pick<CompletionGateConfig, "workspaceRoot" | "completionOutSubdir" | "completionFile">,
): number {
  if (config.completionFile !== undefined) {
    return fileExistsAt({
      workspaceRoot: config.workspaceRoot,
      relativePath: config.completionFile,
    })
      ? 1
      : 0;
  }
  return countCompletionArtifacts(join(config.workspaceRoot, config.completionOutSubdir));
}

const PHASE_DONE_PATH_PATTERN = /^(.*\/)?phase-(\d+)\.done$/u;
const BACKSLASH_PATTERN = /\\/g;

export function inferBlockedFileFromCompletion(completionFile: string): string | undefined {
  const match = PHASE_DONE_PATH_PATTERN.exec(completionFile.replace(BACKSLASH_PATTERN, "/"));
  if (match === null) {
    return undefined;
  }
  const prefix = match[1] ?? "";
  return `${prefix}phase-${match[2]}.blocked`;
}
