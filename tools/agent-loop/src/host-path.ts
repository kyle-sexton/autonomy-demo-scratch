const MSYS_DRIVE_PATH_PATTERN = /^\/([a-zA-Z])\/(.*)$/u;

/**
 * Normalize Git-Bash MSYS paths for Node `fs` and Docker bind mounts on Windows.
 * Without this, `path.resolve("/d/foo")` becomes `D:\d\foo` and breaks file access.
 */
export function normalizeHostFilesystemPath(rawPath: string): string {
  const trimmed = rawPath.trim();
  if (process.platform !== "win32") {
    return trimmed;
  }
  const msysMatch = MSYS_DRIVE_PATH_PATTERN.exec(trimmed);
  const driveLetter = msysMatch?.[1];
  const pathTail = msysMatch?.[2];
  if (driveLetter !== undefined && pathTail !== undefined) {
    const drive = driveLetter.toUpperCase();
    const rest = pathTail.replace(/\\/g, "/");
    return `${drive}:/${rest}`;
  }
  return trimmed.replace(/\\/g, "/");
}
