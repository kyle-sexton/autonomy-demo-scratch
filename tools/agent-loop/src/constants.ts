import type { AgentOutputFormat } from "./types.js";

/** In-container bind mount path for the caller workspace. */
export const CONTAINER_WORKSPACE_MOUNT = "/workspace";

/** Read-only bind mount for agent-loop tool scripts (container probe, etc.). */
export const AGENT_LOOP_TOOL_CONTAINER_MOUNT = "/agent-loop-tool";

/** Default max completion artifacts for the toy example prompt. */
export const TOY_COMPLETION_TARGET = 3;

/** AFK default when `run.local.json` omits `outputFormat` — full NDJSON for observability. */
export const DEFAULT_OUTPUT_FORMAT: AgentOutputFormat = "stream-json";

/** Default relative out dir for the toy example. */
export const DEFAULT_OUT_SUBDIR = "out";

/** Idle timeout — kill when no stdout/stderr for this long (resets on each chunk). */
export const ITERATION_IDLE_TIMEOUT_MS = 10 * 60_000;

/** Max wall-clock backstop for one iteration (independent of idle timer). */
export const ITERATION_MAX_WALL_CLOCK_MS = 60 * 60_000;

/** Grace period after sentinel appears before treating a hung process as iteration-complete. */
export const ITERATION_COMPLETION_GRACE_MS = 60_000;

/** Wall-clock cap for the one-shot container environment probe before the loop. */
export const CONTAINER_PROBE_MAX_WALL_CLOCK_MS = 120_000;

/** Checked-in example prompt (toy backlog). */
export const TOY_PROMPT_PATH = "examples/toy-backlog.prompt.md";

/** Docker label namespace for `docker ps --filter label=agent-loop.run-id=…`. */
export const DOCKER_LABEL_PREFIX = "agent-loop.";

/** Stderr/stdout log line prefix. */
export const LOG_PREFIX = "[agent-loop]";

/** cursor-agent / CLI exited non-zero — stop; operator reviews before re-run (exit 7). */
export const AGENT_FAILED_EXIT_CODE = 7;

/** Host verify script failed after agent completion (exit 8). */
export const HOST_VERIFY_FAILED_EXIT_CODE = 8;

/** Host git config still carries container leaks after repair (exit 9). */
export const HOST_GIT_CONFIG_LEAK_EXIT_CODE = 9;

/** Docker container name prefix (includes CLI + workspace slug + run tail). */
export const CONTAINER_NAME_PREFIX = "agent-loop";

/** Max Docker container name length (spec allows 253; keep headroom). */
export const CONTAINER_NAME_MAX_LEN = 128;
