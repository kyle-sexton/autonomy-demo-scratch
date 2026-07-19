import type { AgentCliAdapter, ContainerInvocation, IterationContext } from "../types.js";

/** Env var cursor-agent reads for subscription auth (confirmed via `--help`). */
const CURSOR_CRED_ENV = "CURSOR_API_KEY";

/**
 * Cursor adapter — builds one headless `cursor-agent` invocation.
 *
 * Flags are Tier-0 confirmed against `cursor-agent --help` inside the built image
 * (version 2026.06.04): `-p/--print` is the non-interactive script mode (full
 * write + shell tools), `-f/--force` allows commands unless explicitly denied,
 * `--trust` skips the workspace-trust prompt (required for headless), the prompt
 * is a positional argument, and auth is via the CURSOR_API_KEY env var.
 *
 * Implement-only: uses `--print` headless mode, never `--mode plan` / `--plan`.
 */
export const cursorAdapter: AgentCliAdapter = (ctx: IterationContext): ContainerInvocation => {
  const command: string[] = [
    "cursor-agent",
    "--print",
    "--force",
    "--trust",
    "--output-format",
    ctx.outputFormat ?? "text",
    "--workspace",
    ctx.containerWorkspacePath,
  ];

  if (ctx.resolvedModelSlug !== undefined) {
    command.push("--model", ctx.resolvedModelSlug);
  }

  // Prompt is the final positional argument (per `cursor-agent --help`).
  command.push(ctx.prompt);

  return {
    requiredEnv: [CURSOR_CRED_ENV],
    command,
    requiresCredential: true,
  };
};
