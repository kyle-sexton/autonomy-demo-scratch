import type { AgentCliAdapter, ContainerInvocation, IterationContext } from "../types.js";

/**
 * Grok Build CLI adapter — one headless `grok -p` invocation per iteration.
 *
 * Subscription auth via bind-mounted `~/.grok/auth.json` (pool credentialBindMounts).
 * Never forward XAI_API_KEY — that selects metered API billing.
 */
export const grokAdapter: AgentCliAdapter = (ctx: IterationContext): ContainerInvocation => {
  const outputFormat =
    ctx.outputFormat === "stream-json" ? "streaming-json" : (ctx.outputFormat ?? "plain");

  const command: string[] = [
    "grok",
    "--no-auto-update",
    "-p",
    ctx.prompt,
    "--always-approve",
    "--output-format",
    outputFormat,
    "--cwd",
    ctx.containerWorkspacePath,
  ];

  if (ctx.resolvedModelSlug !== undefined) {
    command.push("-m", ctx.resolvedModelSlug);
  }

  return {
    requiredEnv: [],
    command,
    requiresCredential: true,
  };
};
