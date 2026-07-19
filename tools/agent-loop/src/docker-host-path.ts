import path from "node:path";

/**
 * Normalize a host filesystem path for `docker run -v` bind mounts.
 *
 * Docker Desktop on Windows accepts drive-letter paths with forward slashes
 * (`C:/Users/...`). Node orchestration uses this helper; Git Bash shell scripts
 * must also set `MSYS_NO_PATHCONV=1` when passing POSIX container paths (`-w /workspace`).
 *
 * Resolves absolute/relative against the named `platform`'s path semantics — not
 * the host's import-time `node:path` binding — so a win32 path normalizes correctly
 * when this runs on a POSIX runner (and vice versa).
 */
export function normalizeDockerBindMountHostPath(
  hostPath: string,
  platform: NodeJS.Platform,
): string {
  const platformPath = platform === "win32" ? path.win32 : path.posix;
  const absolute = platformPath.isAbsolute(hostPath) ? hostPath : platformPath.resolve(hostPath);
  if (platform === "win32") {
    return absolute.replace(/\\/gu, "/");
  }
  return absolute;
}

export function resolveDockerBindMountHostPath(hostPath: string): string {
  return normalizeDockerBindMountHostPath(hostPath, process.platform);
}
