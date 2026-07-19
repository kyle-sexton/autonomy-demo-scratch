import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createLogger, SEVERITY } from "./logger.js";

function getStdoutCalls() {
  return process.stdout.write.mock.calls.map(([chunk]) => String(chunk));
}

describe("SEVERITY", () => {
  it("should map levels to OTEL severity numbers", () => {
    expect(SEVERITY.debug).toBe(5);
    expect(SEVERITY.info).toBe(9);
    expect(SEVERITY.warn).toBe(13);
    expect(SEVERITY.error).toBe(17);
  });
});

describe("createLogger", () => {
  beforeEach(() => {
    vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("should create logger with default info level", () => {
    const log = createLogger();
    expect(log.level).toBe("info");
    expect(log.severity).toBe(9);
  });

  it("should create logger with specified level", () => {
    const log = createLogger("debug");
    expect(log.level).toBe("debug");
    expect(log.severity).toBe(5);
  });

  it("should fall back to info for unknown level", () => {
    const log = createLogger("unknown");
    expect(log.severity).toBe(9);
  });

  describe("level filtering", () => {
    it("should suppress debug at info level", () => {
      const log = createLogger("info");
      log.debug("hidden");
      expect(process.stdout.write).not.toHaveBeenCalled();
    });

    it("should show info at info level", () => {
      const log = createLogger("info");
      log.info("visible");
      expect(process.stdout.write).toHaveBeenCalledWith("visible\n");
    });

    it("should show debug at debug level", () => {
      const log = createLogger("debug");
      log.debug("visible");
      expect(process.stdout.write).toHaveBeenCalledWith("visible\n");
    });

    it("should suppress info and debug at warn level", () => {
      const log = createLogger("warn");
      log.debug("hidden");
      log.info("hidden");
      expect(process.stdout.write).not.toHaveBeenCalled();
    });

    it("should show warn at warn level", () => {
      const log = createLogger("warn");
      log.warn("visible");
      expect(process.stdout.write).toHaveBeenCalledWith("visible\n");
    });

    it("should route error to stderr", () => {
      const log = createLogger("info");
      log.error("error message");
      expect(process.stderr.write).toHaveBeenCalledWith("error message\n");
    });

    it("should pass multiple arguments through", () => {
      const log = createLogger("info");
      log.info("msg", { key: "value" });
      expect(process.stdout.write).toHaveBeenCalledWith('msg {"key":"value"}\n');
    });
  });

  describe("shouldLog", () => {
    it("should return true for levels at or above minimum", () => {
      const log = createLogger("warn");
      expect(log.shouldLog("error")).toBe(true);
      expect(log.shouldLog("warn")).toBe(true);
      expect(log.shouldLog("info")).toBe(false);
      expect(log.shouldLog("debug")).toBe(false);
    });
  });

  describe("logResult", () => {
    it("should log success result with char count for string data", () => {
      const log = createLogger("info");
      log.logResult({
        success: true,
        data: "hello world",
        error: null,
        operation: "extract-transcript",
        durationMs: 45,
        context: { label: 'M1L1 "Welcome"' },
      });

      expect(process.stdout.write).toHaveBeenCalledOnce();
      const output = getStdoutCalls()[0];
      expect(output).toContain("[extract-transcript]");
      expect(output).toContain("M1L1");
      expect(output).toContain("OK");
      expect(output).toContain("11 chars");
      expect(output).toContain("45ms");
    });

    it("should log success result without char count for non-string data", () => {
      const log = createLogger("info");
      log.logResult({
        success: true,
        data: { download: true },
        error: null,
        operation: "detect-resources",
        durationMs: 12,
        context: null,
      });

      const output = getStdoutCalls()[0];
      expect(output).toContain("OK");
      expect(output).toContain("12ms");
      expect(output).not.toContain("chars");
    });

    it("should log failure result with error message", () => {
      const log = createLogger("info");
      log.logResult({
        success: false,
        data: null,
        error: "video player not found",
        operation: "extract-hls-url",
        durationMs: 23,
        context: { label: "M3L1" },
      });

      const output = getStdoutCalls()[0];
      expect(output).toContain("FAIL");
      expect(output).toContain("video player not found");
      expect(output).toContain("23ms");
    });

    it("should suppress success results at warn level", () => {
      const log = createLogger("warn");
      log.logResult({
        success: true,
        data: "text",
        error: null,
        operation: "extract-transcript",
        durationMs: 10,
        context: null,
      });

      expect(process.stdout.write).not.toHaveBeenCalled();
    });

    it("should show failure results at warn level", () => {
      const log = createLogger("warn");
      log.logResult({
        success: false,
        data: null,
        error: "failed",
        operation: "op",
        durationMs: 5,
        context: null,
      });

      expect(process.stdout.write).toHaveBeenCalledOnce();
    });
  });
});
