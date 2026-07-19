import {
  CLAUDE_HEADLESS_MAX_BUDGET_USD,
  CLAUDE_HEADLESS_MAX_TURNS,
  CLAUDE_OAUTH_ENV,
  resolveClaudeHeadlessPermissionMode,
} from "../claude-headless-config.js";
import type { AgentCliAdapter, ContainerInvocation, IterationContext } from "../types.js";

/**
 * Claude Code adapter — one headless `claude -p` invocation per iteration.
 *
 * Fresh context via `--no-session-persistence`. Permission mode and spend caps
 * locked in `claude-headless-config.ts` (see headless-cli-authority.md).
 * Implement-only: never `--mode plan`.
 */
export const claudeAdapter: AgentCliAdapter = (ctx: IterationContext): ContainerInvocation => {
  const command: string[] = [
    "claude",
    "-p",
    "--permission-mode",
    resolveClaudeHeadlessPermissionMode(process.env),
    "--no-session-persistence",
    "--output-format",
    ctx.outputFormat ?? "stream-json",
    "--max-turns",
    String(CLAUDE_HEADLESS_MAX_TURNS),
    "--max-budget-usd",
    String(CLAUDE_HEADLESS_MAX_BUDGET_USD),
  ];

  if (ctx.resolvedModelSlug !== undefined) {
    command.push("--model", ctx.resolvedModelSlug);
  }

  command.push(ctx.prompt);

  return {
    requiredEnv: [CLAUDE_OAUTH_ENV],
    command,
    requiresCredential: true,
  };
};
