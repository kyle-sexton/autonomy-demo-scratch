import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

import {
  buildCapabilitiesResolved,
  clearCapabilityProfileCache,
  loadCapabilityProfile,
} from "./load-profile.js";

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), "../..");
const ID_MISMATCH_PATTERN = /id mismatch/u;

describe("loadCapabilityProfile", () => {
  afterEach(() => {
    clearCapabilityProfileCache();
  });

  it("should load thin profile", () => {
    const profile = loadCapabilityProfile("thin", PROJECT_ROOT);
    expect(profile.id).toBe("thin");
    expect(profile.gitBridge).toBe("auto");
    expect(profile.dependencies.node).toBe(false);
  });

  it("should build capabilitiesResolved from profile and probe", () => {
    const profile = loadCapabilityProfile("cloud-parity", PROJECT_ROOT);
    const resolved = buildCapabilitiesResolved({
      profile,
      gitBridgeLayout: "linked",
      gitBridgeMode: "read-write",
      gitStatusExit: 0,
      observedDependencies: { node: true, dotnet: false },
    });
    expect(resolved.profileId).toBe("cloud-parity");
    expect(resolved.verifyPlane).toBe("container");
    expect(resolved.gitBridge).toEqual({
      layout: "linked",
      mode: "read-write",
      gitStatusExit: 0,
    });
    expect(resolved.dependencies).toEqual({ node: true, dotnet: false });
  });

  it("should throw when profile file id mismatches requested profileId", () => {
    const root = mkdtempSync(join(tmpdir(), "agent-loop-cap-"));
    mkdirSync(join(root, "capabilities"));
    writeFileSync(
      join(root, "capabilities", "mismatch.json"),
      JSON.stringify({
        id: "other",
        gitBridge: "auto",
        verifyPlane: "host",
        dependencies: { node: false, dotnet: false },
      }),
      "utf8",
    );
    expect(() => loadCapabilityProfile("mismatch", root)).toThrow(ID_MISMATCH_PATTERN);
    rmSync(root, { recursive: true, force: true });
  });

  it("should cache loaded profiles until cache is cleared", () => {
    clearCapabilityProfileCache();
    const first = loadCapabilityProfile("thin", PROJECT_ROOT);
    const second = loadCapabilityProfile("thin", PROJECT_ROOT);
    expect(second).toBe(first);
    clearCapabilityProfileCache();
    const reloaded = loadCapabilityProfile("thin", PROJECT_ROOT);
    expect(reloaded).not.toBe(first);
  });
});
