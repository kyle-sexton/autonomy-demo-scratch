import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import type { RunSession } from "./types.js";

const runSingleIteration = vi.fn();

vi.mock("./iteration-runner.js", () => ({
  runSingleIteration,
}));

vi.mock("./run-loop-observability.js", () => ({
  runAndPersistContainerProbe: vi.fn().mockResolvedValue({
    schemaVersion: 1,
    workspace: "/workspace",
    probeExitCode: 0,
  }),
  persistHookReportFromToolCalls: vi.fn(),
}));

const runHostVerifyScript = vi.fn();

vi.mock("./host-verify.js", () => ({
  runHostVerifyScript,
  tailLines: (text: string) => text,
}));

const { runAgentLoop } = await import("./run-loop.js");

function buildSession(workspacePath: string, logsDirectory: string): RunSession {
  return {
    poolId: "cursor-default",
    agentCli: "cursor",
    containerImage: "agent-loop-cursor:thin",
    containerWorkspaceMount: "/workspace",
    maxIterations: 3,
    promptPath: join(workspacePath, "prompt.prompt.md"),
    hostWorkspacePath: workspacePath,
    completionOutSubdir: "out",
    completionTarget: 1,
    runId: "test-run",
    resolvedModelSlug: "test-model",
    logsDirectory,
    capabilityProfileId: "thin",
  };
}

// biome-ignore lint/complexity/noExcessiveLinesPerFunction: integration cases share one fixture harness
describe("runAgentLoop runtime reliability", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.unstubAllEnvs();
    runHostVerifyScript.mockReset();
  });

  function createFixture(): {
    workspacePath: string;
    logsDirectory: string;
    exitCode: { value: number | null };
    logs: string[];
    errors: string[];
    run: () => Promise<void>;
  } {
    const workspacePath = mkdtempSync(join(tmpdir(), "agent-loop-run-"));
    const logsDirectory = join(workspacePath, "logs");
    mkdirSync(logsDirectory, { recursive: true });
    mkdirSync(join(workspacePath, "out"), { recursive: true });
    writeFileSync(join(workspacePath, "prompt.prompt.md"), "do work");
    vi.stubEnv("CURSOR_API_KEY", "crsr_test_key_for_unit_tests");

    const exitCode = { value: null as number | null };
    const logs: string[] = [];
    const errors: string[] = [];

    const ports = {
      filesystem: {
        ensureDirectory: (path: string) => mkdirSync(path, { recursive: true }),
        readTextFile: () => "do work",
        writeTextFile: vi.fn(),
        appendTextFile: vi.fn(),
        appendRawTextFile: vi.fn(),
      },
      console: {
        log: (message: string) => logs.push(message),
        error: (message: string) => errors.push(message),
      },
      exit: {
        exit: (code: number): never => {
          exitCode.value = code;
          throw new Error(`exit:${code}`);
        },
      },
    };

    const run = async (): Promise<void> => {
      try {
        await runAgentLoop({
          session: buildSession(workspacePath, logsDirectory),
          projectRoot: workspacePath,
          ports,
        });
      } catch (error) {
        if (!(error instanceof Error && error.message.startsWith("exit:"))) {
          throw error;
        }
      }
    };

    return { workspacePath, logsDirectory, exitCode, logs, errors, run };
  }

  it("should exit 0 on fs-before-abort when watchdog fires but completion target is met", async () => {
    const fixture = createFixture();
    writeFileSync(join(fixture.workspacePath, "out", "1.txt"), "1");
    runSingleIteration.mockResolvedValueOnce({
      log: "<promise>NO_MORE_TASKS</promise>",
      elapsedMs: 600_000,
      exitCode: 0,
      signal: null,
      killReason: null,
      watchdogTriggered: true,
      completionGraceEnd: false,
      containerName: "agent-loop-cursor-test-i1",
      iterLabel: "iteration-01-cursor",
    });

    await fixture.run();
    expect(fixture.exitCode.value).toBe(0);
    expect(fixture.logs.some((line) => line.includes("fs-before-abort"))).toBe(true);
  });

  it("should exit 2 when watchdog fires and completion target is not met", async () => {
    const fixture = createFixture();
    runSingleIteration.mockResolvedValueOnce({
      log: "partial output",
      elapsedMs: 600_000,
      exitCode: null,
      signal: "SIGTERM",
      killReason: "idle",
      watchdogTriggered: true,
      completionGraceEnd: false,
      containerName: "agent-loop-cursor-test-i1",
      iterLabel: "iteration-01-cursor",
    });

    await fixture.run();
    expect(fixture.exitCode.value).toBe(2);
  });

  it("should exit 7 when agent process fails without auto-continuing", async () => {
    const fixture = createFixture();
    runSingleIteration.mockResolvedValueOnce({
      log: "<promise>NO_MORE_TASKS</promise>",
      elapsedMs: 10_000,
      exitCode: 1,
      signal: null,
      killReason: null,
      watchdogTriggered: false,
      completionGraceEnd: false,
      containerName: "agent-loop-cursor-test-i1",
      iterLabel: "iteration-01-cursor",
    });

    await fixture.run();
    expect(fixture.exitCode.value).toBe(7);
    const stderr = fixture.errors.join("\n");
    expect(stderr).toContain("agent failed — operator review required");
    expect(stderr).toContain('role "mechanical" → composer-2.5-fast');
    expect(stderr).toContain("exit 7");
  });

  it("should exit 8 when host verify fails after agent completion", async () => {
    const fixture = createFixture();
    writeFileSync(join(fixture.workspacePath, "out", "1.txt"), "1");
    runHostVerifyScript.mockReturnValueOnce({
      scriptPath: "/verify.sh",
      exitCode: 1,
      stdout: "FAIL",
      stderr: "",
      passed: false,
    });
    vi.stubEnv("AGENT_LOOP_HOST_VERIFY_SCRIPT", "scripts/verify.sh");

    const session = buildSession(fixture.workspacePath, fixture.logsDirectory);
    const ports = {
      filesystem: {
        ensureDirectory: (path: string) => mkdirSync(path, { recursive: true }),
        readTextFile: () => "do work",
        writeTextFile: vi.fn(),
        appendTextFile: vi.fn(),
        appendRawTextFile: vi.fn(),
      },
      console: {
        log: (message: string) => fixture.logs.push(message),
        error: (message: string) => fixture.errors.push(message),
      },
      exit: {
        exit: (code: number): never => {
          fixture.exitCode.value = code;
          throw new Error(`exit:${code}`);
        },
      },
    };

    runSingleIteration.mockResolvedValueOnce({
      log: "<promise>NO_MORE_TASKS</promise>",
      elapsedMs: 1000,
      exitCode: 0,
      signal: null,
      killReason: null,
      watchdogTriggered: false,
      completionGraceEnd: false,
      containerName: "agent-loop-cursor-test-i1",
      iterLabel: "iteration-01-cursor",
    });

    try {
      await runAgentLoop({
        session: { ...session, hostVerifyScript: "scripts/verify.sh" },
        projectRoot: fixture.workspacePath,
        ports,
      });
    } catch (error) {
      if (!(error instanceof Error && error.message.startsWith("exit:"))) {
        throw error;
      }
    }

    expect(fixture.exitCode.value).toBe(8);
    expect(runHostVerifyScript).toHaveBeenCalled();
  });

  it("should skip iteration 1 when blocked marker is present pre-loop", async () => {
    const fixture = createFixture();
    writeFileSync(join(fixture.workspacePath, "out", "phase-1.blocked"), "blocked");
    vi.stubEnv("AGENT_LOOP_BLOCKED_FILE", "out/phase-1.blocked");

    const session = buildSession(fixture.workspacePath, fixture.logsDirectory);
    const ports = {
      filesystem: {
        ensureDirectory: (path: string) => mkdirSync(path, { recursive: true }),
        readTextFile: () => "do work",
        writeTextFile: vi.fn(),
        appendTextFile: vi.fn(),
        appendRawTextFile: vi.fn(),
      },
      console: {
        log: (message: string) => fixture.logs.push(message),
        error: (message: string) => fixture.errors.push(message),
      },
      exit: {
        exit: (code: number): never => {
          fixture.exitCode.value = code;
          throw new Error(`exit:${code}`);
        },
      },
    };

    try {
      await runAgentLoop({
        session: { ...session, blockedFile: "out/phase-1.blocked" },
        projectRoot: fixture.workspacePath,
        ports,
      });
    } catch (error) {
      if (!(error instanceof Error && error.message.startsWith("exit:"))) {
        throw error;
      }
    }

    expect(fixture.exitCode.value).toBe(3);
    expect(runSingleIteration).not.toHaveBeenCalled();
    expect(fixture.logs.some((line) => line.includes("pre-loop gate"))).toBe(true);
  });

  it("should proceed to decideCompletion when completion grace ends after sentinel", async () => {
    const fixture = createFixture();
    writeFileSync(join(fixture.workspacePath, "out", "1.txt"), "1");
    runSingleIteration.mockResolvedValueOnce({
      log: "<promise>NO_MORE_TASKS</promise>",
      elapsedMs: 61_000,
      exitCode: null,
      signal: "SIGTERM",
      killReason: "completion-grace",
      watchdogTriggered: false,
      completionGraceEnd: true,
      containerName: "agent-loop-cursor-test-i1",
      iterLabel: "iteration-01-cursor",
    });

    await fixture.run();
    expect(fixture.exitCode.value).toBe(0);
    expect(fixture.logs.some((line) => line.includes("completion grace expired"))).toBe(true);
  });
});
