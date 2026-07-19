import { describe, expect, it } from "vitest";

import {
  type ContainerRunSpec,
  createDockerContainerRuntime,
  RecordingContainerRuntime,
} from "./container-runtime.js";

const BASE_SPEC: ContainerRunSpec = {
  image: "agent-loop-cursor:thin",
  name: "agent-loop-cursor-test-i1",
  labels: { "agent-loop.run-id": "test" },
  workspaceHostPath: "/tmp/ws",
  workspaceContainerPath: "/workspace",
  envVarNames: ["CURSOR_API_KEY"],
  command: ["cursor-agent", "--print", "hi"],
  idleTimeoutMs: 1_000,
  maxWallClockMs: 60_000,
  completionGraceMs: 500,
};

describe("RecordingContainerRuntime", () => {
  it("should capture run specs without invoking docker", async () => {
    const runtime = new RecordingContainerRuntime({
      stdout: "ok",
      stderr: "",
      exitCode: 0,
      signal: null,
      elapsedMs: 100,
      killReason: null,
    });

    const result = await runtime.run(BASE_SPEC, {
      onOutputChunk: () => {},
    });

    expect(runtime.runs).toHaveLength(1);
    // biome-ignore lint/suspicious/noUnnecessaryConditions: noUncheckedIndexedAccess (tsconfig.base.json) makes runs[0] RunRecord|undefined, so the ?. is required by tsc; Biome does not honor noUncheckedIndexedAccess.
    expect(runtime.runs[0]?.spec.name).toBe("agent-loop-cursor-test-i1");
    expect(result.stdout).toBe("ok");
  });
});

describe("createDockerContainerRuntime", () => {
  it("should expose docker as the runtime id", () => {
    expect(
      createDockerContainerRuntime(() => {
        throw new Error("not invoked in this test");
      }).id,
    ).toBe("docker");
  });
});
