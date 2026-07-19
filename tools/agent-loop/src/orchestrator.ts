import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { LOG_PREFIX } from "./constants.js";
import { loadProjectEnv } from "./env.js";
import { runAgentLoop } from "./run-loop.js";
import { buildRunSession } from "./session-config.js";
import { writeStderr } from "./stderr.js";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_WORKSPACE_PATH = join(PROJECT_ROOT, "workspace");

async function main(): Promise<void> {
  loadProjectEnv(PROJECT_ROOT);

  const built = buildRunSession({
    projectRoot: PROJECT_ROOT,
    cwd: process.cwd(),
    argv: process.argv,
    defaultWorkspacePath: DEFAULT_WORKSPACE_PATH,
  });

  if (!built.ok) {
    writeStderr(`${LOG_PREFIX} ${built.message}`);
    process.exit(built.exitCode);
  }

  await runAgentLoop({ session: built.session, projectRoot: PROJECT_ROOT });
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  writeStderr(`${LOG_PREFIX} fatal: ${message}`);
  process.exit(1);
});
