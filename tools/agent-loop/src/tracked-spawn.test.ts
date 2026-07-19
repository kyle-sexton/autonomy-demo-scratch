import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";

import { describe, expect, it } from "vitest";

import {
  defaultTrackedSpawnClock,
  runTrackedSpawn,
  type TrackedSpawnClock,
} from "./tracked-spawn.js";

function createFakeChild(options?: { closeOnKill?: boolean }): ChildProcessWithoutNullStreams {
  const closeOnKill = options?.closeOnKill ?? true;
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const child = new EventEmitter() as ChildProcessWithoutNullStreams;
  child.stdout = stdout;
  child.stderr = stderr;
  child.kill = (signal?: NodeJS.Signals) => {
    if (closeOnKill || signal === "SIGKILL") {
      child.emit("close", null, signal ?? "SIGTERM");
    }
    return true;
  };
  return child;
}

function createManualClock(startMs = 0): TrackedSpawnClock & { advance: (ms: number) => void } {
  let nowMs = startMs;
  const sleepers: Array<{ wakeAt: number; resolve: () => void }> = [];

  const flushSleepers = (): void => {
    const pending = sleepers.splice(0, sleepers.length);
    for (const sleeper of pending) {
      if (sleeper.wakeAt <= nowMs) {
        sleeper.resolve();
      } else {
        sleepers.push(sleeper);
      }
    }
  };

  return {
    now: () => nowMs,
    sleep: (ms) =>
      new Promise((resolve) => {
        sleepers.push({ wakeAt: nowMs + ms, resolve });
        flushSleepers();
      }),
    advance(ms: number) {
      nowMs += ms;
      flushSleepers();
    },
  };
}

describe("runTrackedSpawn", () => {
  it("should complete successfully when the child exits on its own", async () => {
    const child = createFakeChild();
    const clock = createManualClock();

    const outcomePromise = runTrackedSpawn({
      command: "docker",
      args: ["run"],
      config: { idleTimeoutMs: 5_000, maxWallClockMs: 60_000, completionGraceMs: 1_000 },
      spawnFn: () => {
        queueMicrotask(() => {
          child.emit("close", 0, null);
        });
        return child;
      },
      clock,
      pollIntervalMs: 10,
    });

    const outcome = await outcomePromise;
    expect(outcome.killReason).toBeNull();
    expect(outcome.exitCode).toBe(0);
  });

  it("should end via completion grace when sentinel appears then the process hangs", async () => {
    const child = createFakeChild();

    const outcome = await runTrackedSpawn({
      command: "docker",
      args: ["run"],
      config: { idleTimeoutMs: 60_000, maxWallClockMs: 120_000, completionGraceMs: 50 },
      spawnFn: () => {
        setTimeout(() => {
          child.stdout.write("<promise>NO_MORE_TASKS</promise>\n");
        }, 10);
        return child;
      },
      clock: defaultTrackedSpawnClock,
      pollIntervalMs: 10,
    });

    expect(outcome.killReason).toBe("completion-grace");
    expect(outcome.stdout).toContain("NO_MORE_TASKS");
  }, 10_000);

  it("should invoke onOutputChunk for stdout and stderr", async () => {
    const child = createFakeChild();
    const chunks: Array<{ chunk: string; stream: "stdout" | "stderr" }> = [];

    const outcomePromise = runTrackedSpawn({
      command: "docker",
      args: ["run"],
      config: { idleTimeoutMs: 5_000, maxWallClockMs: 60_000, completionGraceMs: 1_000 },
      spawnFn: () => child,
      clock: createManualClock(),
      pollIntervalMs: 10,
      options: {
        onOutputChunk: (chunk, stream) => {
          chunks.push({ chunk, stream });
        },
      },
    });

    child.stdout.write("a");
    child.stderr.write("b");
    child.emit("close", 0, null);

    await outcomePromise;
    expect(chunks).toEqual([
      { chunk: "a", stream: "stdout" },
      { chunk: "b", stream: "stderr" },
    ]);
  });

  it("should not enter completion grace for stream-json prompt echo without result event", async () => {
    const child = createFakeChild();
    const clock = createManualClock();

    const outcomePromise = runTrackedSpawn({
      command: "docker",
      args: ["run"],
      config: { idleTimeoutMs: 1_000, maxWallClockMs: 60_000, completionGraceMs: 50 },
      spawnFn: () => child,
      clock,
      pollIntervalMs: 10,
      options: { outputFormat: "stream-json" },
    });

    child.stdout.write(
      '{"type":"user","message":"Emit CONTINUE promise token when work remains."}\n',
    );
    clock.advance(100);
    await Promise.resolve();
    clock.advance(2_000);

    const outcome = await outcomePromise;
    expect(outcome.killReason).toBe("idle");
  });

  it("should kill on idle timeout when output stops and no sentinel appears", async () => {
    const child = createFakeChild();
    const clock = createManualClock();

    const outcomePromise = runTrackedSpawn({
      command: "docker",
      args: ["run"],
      config: { idleTimeoutMs: 1_000, maxWallClockMs: 60_000, completionGraceMs: 500 },
      spawnFn: () => child,
      clock,
      pollIntervalMs: 100,
    });

    child.stdout.push("working...\n");
    clock.advance(100);
    await Promise.resolve();
    clock.advance(1_000);
    const outcome = await outcomePromise;

    expect(outcome.killReason).toBe("idle");
  });

  it("should escalate to SIGKILL when SIGTERM does not stop the child", async () => {
    const child = createFakeChild({ closeOnKill: false });
    const killSignals: string[] = [];
    child.kill = (signal?: NodeJS.Signals) => {
      killSignals.push(signal ?? "SIGTERM");
      if (signal === "SIGKILL") {
        child.emit("close", null, "SIGKILL");
      }
      return true;
    };

    const outcomePromise = runTrackedSpawn({
      command: "docker",
      args: ["run"],
      config: { idleTimeoutMs: 30, maxWallClockMs: 60_000, completionGraceMs: 10 },
      spawnFn: () => child,
      pollIntervalMs: 10,
      sigtermGraceMs: 50,
    });

    child.stdout.write("working...\n");
    const outcome = await outcomePromise;

    expect(outcome.killReason).toBe("idle");
    expect(killSignals).toEqual(["SIGTERM", "SIGKILL"]);
  }, 15_000);
});
