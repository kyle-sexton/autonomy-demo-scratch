/** Supported headless agent CLI kinds (adapter registry keys). */
export type AgentCliKind = "cursor" | "claude" | "codex" | "grok";

/** Sentinel the agent prints on the final line of each iteration. */
export type Sentinel = "CONTINUE" | "NO_MORE_TASKS";

/** Orchestrator decision after one iteration. */
export type IterationDecision = "continue" | "done" | "stuck" | "failed";

export interface CompletionResult {
  readonly decision: IterationDecision;
  readonly mismatch: boolean;
  readonly reason: string;
}

export type AgentOutputFormat = "text" | "json" | "stream-json";

/**
 * Optional extra bind mount (e.g. read-only sibling repo).
 * Orchestrator merges with primary workspace mount.
 */
export interface WorkspaceBindMount {
  readonly hostPath: string;
  readonly containerPath: string;
  readonly readOnly?: boolean;
}

/** Resolved inputs for one orchestrator invocation. */
export interface RunSession {
  readonly poolId: string;
  readonly agentCli: AgentCliKind;
  readonly containerImage: string;
  readonly containerWorkspaceMount: string;
  readonly maxIterations: number;
  readonly promptPath: string;
  /** Host path bind-mounted as the agent workspace (any directory — not repo-scoped). */
  readonly hostWorkspacePath: string;
  readonly completionOutSubdir: string;
  readonly completionTarget: number;
  /** Repo-relative completion marker (slice harness). When set, overrides file-count target. */
  readonly completionFile?: string;
  readonly blockedFile?: string;
  readonly selfCheckFile?: string;
  /** Repo-relative host verify script — orchestrator runs after agent claims done. */
  readonly hostVerifyScript?: string;
  readonly runId: string;
  readonly resolvedModelSlug: string;
  readonly outputFormat?: AgentOutputFormat;
  readonly logsDirectory: string;
  readonly additionalBindMounts?: readonly WorkspaceBindMount[];
  /** Orchestrator-computed container env (e.g. GIT_DIR for linked worktrees). */
  readonly additionalContainerEnv?: Readonly<Record<string, string>>;
  readonly capabilityProfileId: string;
  /** Optional `docker run --user uid:gid` for Linux bind-mount ownership. */
  readonly containerRunUser?: string;
}
