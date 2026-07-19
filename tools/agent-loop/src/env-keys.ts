/**
 * Canonical orchestrator environment variables.
 * Legacy `RALPH_*` names remain supported as fallbacks for older scripts.
 */

export const ENV = {
  blockedFile: ["AGENT_LOOP_BLOCKED_FILE"],
  completionFile: ["AGENT_LOOP_COMPLETION_FILE"],
  containerUid: ["AGENT_LOOP_UID"],
  containerGid: ["AGENT_LOOP_GID"],
  completionTarget: ["AGENT_LOOP_COMPLETION_TARGET", "RALPH_TARGET"],
  hostVerifyScript: ["AGENT_LOOP_HOST_VERIFY_SCRIPT"],
  logDirectory: ["AGENT_LOOP_LOG_DIR", "RALPH_LOG_DIR"],
  maxIterations: ["AGENT_LOOP_MAX_ITERATIONS", "RALPH_MAX_ITERATIONS"],
  model: ["AGENT_LOOP_MODEL", "RALPH_MODEL"],
  outSubdir: ["AGENT_LOOP_OUT_SUBDIR", "RALPH_OUT_SUBDIR"],
  pool: ["AGENT_LOOP_POOL", "RALPH_POOL"],
  prompt: ["AGENT_LOOP_PROMPT", "RALPH_PROMPT"],
  runId: ["AGENT_LOOP_RUN_ID", "RALPH_RUN_ID"],
  selfCheckFile: ["AGENT_LOOP_SELF_CHECK_FILE"],
  workspace: ["AGENT_LOOP_WORKSPACE", "RALPH_WORKSPACE"],
} as const;

/** First set non-empty value from `process.env` for the given key aliases. */
export function readEnv(keys: readonly string[]): string | undefined {
  for (const key of keys) {
    const value = process.env[key];
    if (value !== undefined && value.trim() !== "") {
      return value.trim();
    }
  }
  return undefined;
}
