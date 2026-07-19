import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { DOCKER_LABEL_PREFIX } from "./constants.js";
import {
  buildContainerName,
  buildDockerRunArgs,
  buildDockerRunIdentity,
  createRunId,
  resolveRunLogsDirectory,
  workspaceSlugFromPath,
} from "./docker-run.js";

const RUN_ID_WITH_WORKSPACE_SLUG_PATTERN = /^20260610T004442781Z-my-feature-[0-9a-f]{6}$/;
const RUN_ID_WITH_LABEL_OVERRIDE_PATTERN = /^20260610T004442781Z-regression-smoke-[0-9a-f]{6}$/;

describe("createRunId", () => {
  it("should date-prefix run folders with workspace slug", () => {
    const runId = createRunId(new Date("2026-06-10T00:44:42.781Z"), undefined, "my-feature");
    expect(runId).toMatch(RUN_ID_WITH_WORKSPACE_SLUG_PATTERN);
  });

  it("should use run label override as suffix when set", () => {
    const runId = createRunId(new Date("2026-06-10T00:44:42.781Z"), "regression-smoke");
    expect(runId).toMatch(RUN_ID_WITH_LABEL_OVERRIDE_PATTERN);
  });
});

describe("workspaceSlug", () => {
  it("should slugify the basename of the workspace path", () => {
    expect(workspaceSlugFromPath("/repo/slices/my-feature")).toBe("my-feature");
    expect(workspaceSlugFromPath(join("worktrees", "feature-foo"))).toBe("feature-foo");
  });
});

const CONTAINER_NAME_PREFIX_PATTERN = /^agent-loop-cursor-my-feature-/;
const ITERATION_SUFFIX_PATTERN = /-i2$/;

describe("containerName", () => {
  it("should embed CLI, workspace slug, run tail, and iteration", () => {
    const name = buildContainerName({
      cli: "cursor",
      workspaceSlug: "my-feature",
      runId: "2026-06-10T004442781Z",
      iteration: 2,
    });
    expect(name).toMatch(CONTAINER_NAME_PREFIX_PATTERN);
    expect(name).toMatch(ITERATION_SUFFIX_PATTERN);
  });
});

describe("dockerIdentity", () => {
  it("should attach agent-loop.* labels for Docker Desktop filtering", () => {
    const id = buildDockerRunIdentity({
      cli: "cursor",
      workspacePath: "/repo/slices/my-task",
      runId: "run-abc",
      iteration: 1,
      iterLabel: "iteration-01-cursor",
    });
    expect(id.containerName).toContain("agent-loop-cursor-my-task");
    expect(id.labels[`${DOCKER_LABEL_PREFIX}cli`]).toBe("cursor");
    expect(id.labels[`${DOCKER_LABEL_PREFIX}run-id`]).toBe("run-abc");
    expect(id.labels[`${DOCKER_LABEL_PREFIX}workspace-slug`]).toBe("my-task");
    expect(id.labels[`${DOCKER_LABEL_PREFIX}iteration`]).toBe("1");
    expect(id.labels[`${DOCKER_LABEL_PREFIX}iter-label`]).toBe("iteration-01-cursor");
  });
});

describe("resolveRunLogsDirectory", () => {
  it("should nest logs under run id", () => {
    expect(resolveRunLogsDirectory("/tool", "run-abc")).toBe("/tool/logs/runs/run-abc");
  });

  it("should honor log directory override", () => {
    expect(resolveRunLogsDirectory("/tool", "run-abc", "/var/log/agent-loop")).toBe(
      "/var/log/agent-loop/runs/run-abc",
    );
  });
});

describe("dockerRunArgs", () => {
  it("should pass --user when runAsUser is set", () => {
    const args = buildDockerRunArgs({
      image: "agent-loop-cursor:thin",
      containerName: "agent-loop-cursor-demo-run-i1",
      workspaceHostPath: "/host/ws",
      workspaceContainerPath: "/workspace",
      requiredEnv: ["CURSOR_API_KEY"],
      command: ["cursor-agent", "--print", "hi"],
      labels: { [`${DOCKER_LABEL_PREFIX}cli`]: "cursor" },
      runAsUser: "1000:1000",
    });
    expect(args).toContain("--user");
    expect(args).toContain("1000:1000");
  });

  it("should include --name and bind mount before the image", () => {
    const args = buildDockerRunArgs({
      image: "agent-loop-cursor:thin",
      containerName: "agent-loop-cursor-demo-run-i1",
      workspaceHostPath: "/host/ws",
      workspaceContainerPath: "/workspace",
      requiredEnv: ["CURSOR_API_KEY"],
      command: ["cursor-agent", "--print", "hi"],
      labels: { [`${DOCKER_LABEL_PREFIX}cli`]: "cursor" },
    });
    expect(args).toContain("--name");
    expect(args).toContain("agent-loop-cursor-demo-run-i1");
    expect(args).toContain("-w");
    expect(args).toContain("/workspace");
    expect(args).toContain("-v");
    expect(args).toContain("/host/ws:/workspace");
    expect(args).toContain("-e");
    expect(args).toContain("CURSOR_API_KEY");
    expect(args.indexOf("agent-loop-cursor:thin")).toBeLessThan(args.indexOf("cursor-agent"));
  });

  it("should append optional read-only bind mounts", () => {
    const args = buildDockerRunArgs({
      image: "agent-loop-cursor:thin",
      containerName: "agent-loop-cursor-demo-i1",
      workspaceHostPath: "/host/primary",
      workspaceContainerPath: "/workspace",
      requiredEnv: [],
      command: ["cursor-agent"],
      labels: {},
      additionalBindMounts: [
        { hostPath: "/host/other-repo", containerPath: "/other", readOnly: true },
      ],
    });
    expect(args).toContain("/host/primary:/workspace");
    expect(args).toContain("/host/other-repo:/other:ro");
  });

  it("should pass additionalContainerEnv as -e KEY=value", () => {
    const args = buildDockerRunArgs({
      image: "agent-loop-cursor:thin",
      containerName: "agent-loop-cursor-demo-i1",
      workspaceHostPath: "/host/primary",
      workspaceContainerPath: "/workspace",
      requiredEnv: ["CURSOR_API_KEY"],
      command: ["cursor-agent"],
      labels: {},
      additionalContainerEnv: {
        GIT_DIR: "/.agent-loop-git/bare/worktrees/slice",
        GIT_WORK_TREE: "/workspace",
      },
    });
    expect(args).toContain("-e");
    expect(args).toContain("GIT_DIR=/.agent-loop-git/bare/worktrees/slice");
    expect(args).toContain("GIT_WORK_TREE=/workspace");
  });
});
