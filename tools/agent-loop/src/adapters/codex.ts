import type { AgentCliAdapter, ContainerInvocation, IterationContext } from "../types.js";

/**
 * Codex CLI adapter — one headless `codex exec` invocation per iteration.
 *
 * Subscription auth via bind-mounted `~/.codex/auth.json` (pool credentialBindMounts).
 * Never forward OPENAI_API_KEY / CODEX_API_KEY — those select metered API billing.
 */
export const codexAdapter: AgentCliAdapter = (ctx: IterationContext): ContainerInvocation => {
  const command: string[] = [
    "codex",
    "exec",
    "--json",
    "--full-auto",
    "--sandbox",
    "workspace-write",
  ];

  if (ctx.resolvedModelSlug !== undefined) {
    command.push("--model", ctx.resolvedModelSlug);
  }

  command.push(ctx.prompt);

  return {
    requiredEnv: [],
    command,
    requiresCredential: true,
  };
};
