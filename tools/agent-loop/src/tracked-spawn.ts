import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { spawn } from "node:child_process";

import {
  evaluateIterationTimeout,
  type IterationTimeoutConfig,
  type TimeoutKillReason,
} from "./iteration-timeout.js";
import {
  createSentinelStreamDetector,
  type SentinelStreamDetector,
} from "./sentinel-stream-detector.js";
import type { AgentOutputFormat } from "./types.js";

export interface TrackedSpawnOutcome {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly elapsedMs: number;
  readonly killReason: TimeoutKillReason | null;
}

export type TrackedSpawnFn = (
  command: string,
  args: readonly string[],
) => ChildProcessWithoutNullStreams;

export interface TrackedSpawnClock {
  readonly now: () => number;
  readonly sleep: (ms: number) => Promise<void>;
}

const DEFAULT_POLL_INTERVAL_MS = 100;
const SIGTERM_GRACE_MS = 5_000;

export const defaultTrackedSpawnClock: TrackedSpawnClock = {
  now: () => Date.now(),
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
};

/**
 * Spawn a process and collect output with idle timeout, completion grace after sentinel,
 * and optional max wall-clock backstop.
 */
export interface TrackedSpawnOptions {
  readonly outputFormat?: AgentOutputFormat;
  readonly sentinelDetector?: SentinelStreamDetector;
  readonly onOutputChunk?: (chunk: string, stream: "stdout" | "stderr") => void;
}

export interface TrackedSpawnInput {
  readonly command: string;
  readonly args: readonly string[];
  readonly config: IterationTimeoutConfig;
  readonly spawnFn?: TrackedSpawnFn;
  readonly clock?: TrackedSpawnClock;
  readonly pollIntervalMs?: number;
  readonly sigtermGraceMs?: number;
  readonly options?: TrackedSpawnOptions;
}

export async function runTrackedSpawn(input: TrackedSpawnInput): Promise<TrackedSpawnOutcome> {
  const {
    command,
    args,
    config,
    spawnFn = spawn,
    clock = defaultTrackedSpawnClock,
    pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
    sigtermGraceMs = SIGTERM_GRACE_MS,
    options = {},
  } = input;
  const { outputFormat, onOutputChunk } = options;
  const sentinelDetector = options.sentinelDetector ?? createSentinelStreamDetector(outputFormat);
  const child = spawnFn(command, args);
  const startedAt = clock.now();
  let lastOutputAt = startedAt;
  let sentinelSeenAtMs: number | null = null;
  let stdout = "";
  let stderr = "";
  let killReason: TimeoutKillReason | null = null;

  const onChunk = (): void => {
    const now = clock.now();
    lastOutputAt = now;
    if (sentinelSeenAtMs === null && sentinelDetector.scan(`${stdout}${stderr}`)) {
      sentinelSeenAtMs = now;
    }
  };

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    stdout += chunk;
    onOutputChunk?.(chunk, "stdout");
    onChunk();
  });
  child.stderr.on("data", (chunk: string) => {
    stderr += chunk;
    onOutputChunk?.(chunk, "stderr");
    onChunk();
  });

  const exitPromise = new Promise<{ exitCode: number | null; signal: NodeJS.Signals | null }>(
    (resolve) => {
      child.once("close", (code, signal) => {
        resolve({ exitCode: code, signal });
      });
      child.once("error", () => {
        resolve({ exitCode: null, signal: null });
      });
    },
  );

  while (killReason === null) {
    // biome-ignore lint/performance/noAwaitInLoops: watchdog poll loop — races exit vs interval until kill or completion.
    const raced = await Promise.race([
      exitPromise.then((result) => ({ kind: "exit" as const, result })),
      clock.sleep(pollIntervalMs).then(() => ({ kind: "poll" as const })),
    ]);

    if (raced.kind === "exit") {
      return {
        stdout,
        stderr,
        exitCode: raced.result.exitCode,
        signal: raced.result.signal,
        elapsedMs: clock.now() - startedAt,
        killReason: null,
      };
    }

    const now = clock.now();
    const elapsedMs = now - startedAt;
    const evaluation = evaluateIterationTimeout({
      elapsedMs,
      msSinceLastOutput: now - lastOutputAt,
      msSinceSentinel: sentinelSeenAtMs === null ? null : now - sentinelSeenAtMs,
      config,
    });

    if (evaluation.shouldKill && evaluation.reason !== null) {
      killReason = evaluation.reason;
      child.kill("SIGTERM");
      const termRace = await Promise.race([
        exitPromise.then((result) => ({ kind: "exit" as const, result })),
        clock.sleep(sigtermGraceMs).then(() => ({ kind: "grace-expired" as const })),
      ]);
      if (termRace.kind === "grace-expired") {
        child.kill("SIGKILL");
      }
      const result = termRace.kind === "exit" ? termRace.result : await exitPromise;
      return {
        stdout,
        stderr,
        exitCode: result.exitCode,
        signal: result.signal,
        elapsedMs: clock.now() - startedAt,
        killReason,
      };
    }
  }

  const result = await exitPromise;
  return {
    stdout,
    stderr,
    exitCode: result.exitCode,
    signal: result.signal,
    elapsedMs: clock.now() - startedAt,
    killReason,
  };
}
