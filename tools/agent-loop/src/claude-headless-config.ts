import { CLAUDE_NON_ROOT_CONTAINER_USER, resolveContainerRunUser } from "./container-user.js";

/** Headless `claude -p` flags locked by flag-matrix.md / headless-cli-authority.md Claude section. */
export const CLAUDE_HEADLESS_PERMISSION_MODE = "bypassPermissions";

export const CLAUDE_HEADLESS_MAX_TURNS = 40;

export const CLAUDE_HEADLESS_MAX_BUDGET_USD = 2;

export const CLAUDE_OAUTH_ENV = "CLAUDE_CODE_OAUTH_TOKEN";

export const CLAUDE_METERED_ENV = "ANTHROPIC_API_KEY";

export const CLAUDE_PERMISSION_PROBE_ENV = "AGENT_LOOP_CLAUDE_PERMISSION_PROBE";

const CLAUDE_PERMISSION_PROBE_MODES = new Set([
  "acceptEdits",
  "auto",
  "bypassPermissions",
  "dontAsk",
]);

export function resolveClaudeHeadlessPermissionMode(env: NodeJS.ProcessEnv): string {
  const probe = env[CLAUDE_PERMISSION_PROBE_ENV]?.trim();
  if (probe === undefined || probe === "" || !CLAUDE_PERMISSION_PROBE_MODES.has(probe)) {
    return CLAUDE_HEADLESS_PERMISSION_MODE;
  }
  return probe;
}

export function claudeOAuthTokenMessage(env: NodeJS.ProcessEnv): string | undefined {
  const token = env[CLAUDE_OAUTH_ENV];
  if (token === undefined || token.trim() === "") {
    return `${CLAUDE_OAUTH_ENV} is required (tools/agent-loop/.env or OS env)`;
  }
  return undefined;
}

export function claudeMeteredOverrideMessage(env: NodeJS.ProcessEnv): string | undefined {
  const apiKey = env[CLAUDE_METERED_ENV];
  if (apiKey !== undefined && apiKey.trim() !== "") {
    return `${CLAUDE_METERED_ENV} must not be set when using Claude subscription pool — unset it to avoid metered override`;
  }
  return undefined;
}

export function validateClaudeSubscriptionAuth(env: NodeJS.ProcessEnv): string | undefined {
  return claudeOAuthTokenMessage(env) ?? claudeMeteredOverrideMessage(env);
}

/**
 * Claude `bypassPermissions` refuses root — use explicit env, workspace owner, or 1000:1000.
 */
export function resolveClaudeContainerRunUser(
  workspacePath: string,
  platform: NodeJS.Platform = process.platform,
): string {
  const resolved = resolveContainerRunUser(workspacePath, platform);
  if (resolved === undefined || resolved === "0:0") {
    return CLAUDE_NON_ROOT_CONTAINER_USER;
  }
  return resolved;
}
