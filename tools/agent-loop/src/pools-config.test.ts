import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { CURSOR_AGENT_POOL, resolveAgentPool } from "./agent-pool.js";
import {
  loadPoolsLocalConfig,
  PoolsLocalConfigError,
  parsePoolsLocalConfig,
  resolveGateMarkerPath,
  stripJsonComments,
} from "./pools-config.js";

describe("loadPoolsLocalConfig", () => {
  it("should throw when pools.local.jsonc exists but is invalid", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-pools-"));
    writeFileSync(join(dir, "pools.local.jsonc"), "{ invalid jsonc");
    expect(() => loadPoolsLocalConfig(dir)).toThrow(PoolsLocalConfigError);
  });

  it("should return empty config when pools.local.jsonc is absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-pools-missing-"));
    expect(loadPoolsLocalConfig(dir)).toEqual({});
  });
});

const DISABLED_POOL_RE = /disabled/;

describe("stripJsonComments", () => {
  it("should remove line and block comments outside strings", () => {
    const raw = `{
      // line comment
      "defaultPoolId": "cursor-default",
      /* block */
      "pools": {}
    }`;
    expect(JSON.parse(stripJsonComments(raw))).toEqual({
      defaultPoolId: "cursor-default",
      pools: {},
    });
  });

  it("should preserve // inside JSON string values", () => {
    const raw = '{"pools":{"x":{"containerImage":"registry.io/app:1.0//stable"}}}';
    expect(JSON.parse(stripJsonComments(raw))).toEqual({
      pools: { x: { containerImage: "registry.io/app:1.0//stable" } },
    });
  });
});

describe("parsePoolsLocalConfig", () => {
  it("should parse defaultPoolId and pool overrides", () => {
    const config = parsePoolsLocalConfig(
      '{"defaultPoolId":"claude-default","pools":{"claude-default":{"enabled":true}}}',
    );
    expect(config.defaultPoolId).toBe("claude-default");
    expect(config.pools?.["claude-default"]?.enabled).toBe(true);
  });

  it("should reject credential bind mounts with empty paths or ..", () => {
    expect(() =>
      parsePoolsLocalConfig(
        '{"pools":{"codex-default":{"credentialBindMounts":[{"hostPath":"","containerPath":"/x"}]}}}',
      ),
    ).toThrow(PoolsLocalConfigError);
    expect(() =>
      parsePoolsLocalConfig(
        '{"pools":{"codex-default":{"credentialBindMounts":[{"hostPath":"~/.codex/auth.json","containerPath":"../escape"}]}}}',
      ),
    ).toThrow(PoolsLocalConfigError);
  });
});

describe("resolveGateMarkerPath", () => {
  it("should reject gateMarkerFile with .. traversal", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-gate-marker-"));
    expect(() =>
      resolveGateMarkerPath(dir, "cursor-default", "operator/marker.json", {
        pools: { "cursor-default": { gateMarkerFile: "../../outside/marker.json" } },
      }),
    ).toThrow(PoolsLocalConfigError);
  });

  it("should resolve relative override under project root", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-gate-marker-ok-"));
    const path = resolveGateMarkerPath(dir, "cursor-default", "operator/default.json", {
      pools: { "cursor-default": { gateMarkerFile: "operator/custom.json" } },
    });
    expect(path).toBe(join(dir, "operator/custom.json"));
  });

  it("should default to project root plus default filename", () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-loop-gate-marker-default-"));
    expect(
      resolveGateMarkerPath(dir, "cursor-default", CURSOR_AGENT_POOL.gateMarkerFilename, {}),
    ).toBe(join(dir, CURSOR_AGENT_POOL.gateMarkerFilename));
  });
});

describe("resolveAgentPool", () => {
  it("should default to cursor-default", () => {
    const pool = resolveAgentPool(undefined, "/tool", {});
    expect(pool.id).toBe("cursor-default");
  });

  it("should refuse disabled pools", () => {
    expect(() =>
      resolveAgentPool("claude-default", "/tool", {
        pools: { "claude-default": { enabled: false } },
      }),
    ).toThrow(DISABLED_POOL_RE);
  });

  it("should honor containerImage override", () => {
    const pool = resolveAgentPool("cursor-default", "/tool", {
      pools: { "cursor-default": { containerImage: "custom:tag" } },
    });
    expect(pool.containerImage).toBe("custom:tag");
  });
});
