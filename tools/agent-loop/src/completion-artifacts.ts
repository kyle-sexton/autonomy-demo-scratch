import { existsSync, readdirSync } from "node:fs";

/**
 * Count regular files in a completion directory (ground-truth progress).
 * Ignores dotfiles and subdirectories — prompt defines what those files mean.
 */
export function countCompletionArtifacts(directory: string): number {
  if (!existsSync(directory)) {
    return 0;
  }
  return readdirSync(directory, { withFileTypes: true }).filter(
    (entry) => entry.isFile() && !entry.name.startsWith("."),
  ).length;
}
