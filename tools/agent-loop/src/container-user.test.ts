import { describe, expect, it } from "vitest";

import { resolveContainerRunUser } from "./container-user.js";

const LINUX_UID_GID_PATTERN = /^\d+:\d+$/;

describe("resolveContainerRunUser", () => {
  it("should prefer explicit uid and gid arguments", () => {
    expect(resolveContainerRunUser("/tmp/ws", "linux", "1001", "1002")).toBe("1001:1002");
  });

  it("should omit --user on Windows and macOS when env is unset", () => {
    expect(resolveContainerRunUser("/tmp/ws", "win32")).toBeUndefined();
    expect(resolveContainerRunUser("/tmp/ws", "darwin")).toBeUndefined();
  });

  it("should derive uid:gid from workspace stat on Linux when env is unset", () => {
    const user = resolveContainerRunUser(".", "linux");
    expect(user).toMatch(LINUX_UID_GID_PATTERN);
  });
});
