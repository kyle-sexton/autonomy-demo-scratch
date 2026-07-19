import { isAbsolute, resolve, sep } from "node:path";

/** Repo-root path plus a path relative to that root (or absolute). */
export interface WorkspaceRelativePath {
  readonly workspaceRoot: string;
  readonly relativePath: string;
}

export class WorkspacePathError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WorkspacePathError";
  }
}

const WINDOWS_DRIVE_PATH_PATTERN = /^[A-Za-z]:/u;

function isAbsolutePath(path: string): boolean {
  return isAbsolute(path) || WINDOWS_DRIVE_PATH_PATTERN.test(path);
}

/** Reject `..` segments before resolve — mirrors mcp-launcher assertRepoRelativeDir. */
export function assertNoPathTraversal(relativePath: string): void {
  const slashNormalized = relativePath.replace(/\\/g, "/");
  if (slashNormalized.split("/").includes("..")) {
    throw new WorkspacePathError(`Repo-relative path must not contain '..': ${relativePath}`);
  }
}

export function assertPathUnderRoot(resolvedPath: string, root: string): string {
  const normalizedRoot = resolve(root);
  const normalized = resolve(resolvedPath);
  if (normalized !== normalizedRoot && !normalized.startsWith(`${normalizedRoot}${sep}`)) {
    throw new WorkspacePathError(`Path escapes workspace root: ${resolvedPath}`);
  }
  return normalized;
}

export function resolvePathUnderRoot(input: WorkspaceRelativePath): string {
  const trimmed = input.relativePath.trim();
  if (trimmed === "") {
    throw new WorkspacePathError("Relative path must be non-empty");
  }
  if (!isAbsolutePath(trimmed)) {
    assertNoPathTraversal(trimmed);
  }
  const resolved = isAbsolutePath(trimmed)
    ? resolve(trimmed)
    : resolve(input.workspaceRoot, trimmed);
  return assertPathUnderRoot(resolved, input.workspaceRoot);
}
