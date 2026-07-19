#!/usr/bin/env node
// MCP package dispatch: cross-platform npx spawn OR worktree-scoped repo server.
//
// npx servers:  node launcher.js -y @scope/pkg …
// repo servers: node launcher.js mcp-servers/<name>/node node build/index.js
//
// MCP hosts spawn fnm exec first (see tools/mcp-launcher/README.md); set
// MCP_LAUNCHER_FNM_ACTIVE=1 so this file does not double-wrap. Manual dev may
// invoke launcher.js directly — fnm wrap runs when fnm is on PATH.

const { spawn, spawnSync } = require("node:child_process");
const { attachLifecycle, dispatch } = require("./dispatch.js");

const forwardArgs = process.argv.slice(2);

function fnmOnPath() {
  if (process.platform === "win32") {
    const result = spawnSync("where", ["fnm"], { encoding: "utf8", stdio: "pipe" });
    return result.status === 0;
  }
  const result = spawnSync("command", ["-v", "fnm"], {
    encoding: "utf8",
    stdio: "pipe",
    shell: true,
  });
  return result.status === 0;
}

if (process.env.MCP_LAUNCHER_FNM_ACTIVE) {
  dispatch(forwardArgs);
} else if (fnmOnPath()) {
  const fnmArgs = [
    "exec",
    "--version-file-strategy=recursive",
    "--using=.nvmrc",
    "--",
    "node",
    __filename,
    ...forwardArgs,
  ];
  attachLifecycle(
    spawn("fnm", fnmArgs, {
      stdio: "inherit",
      env: { ...process.env, MCP_LAUNCHER_FNM_ACTIVE: "1" },
    }),
    "mcp-launcher",
  );
} else {
  // No fnm and no parent fnm-exec wrap — fall back to ambient node.
  process.stderr.write(
    "mcp-launcher: fnm not on PATH — using ambient node (run /onboard fix Phase 1)\n",
  );
  dispatch(forwardArgs);
}
