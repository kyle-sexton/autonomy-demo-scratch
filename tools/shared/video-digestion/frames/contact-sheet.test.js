import { describe, expect, it, vi } from "vitest";

import {
  computeMontageGeometry,
  createContactSheet,
  DEFAULT_CANVAS_HEIGHT,
  DEFAULT_CANVAS_WIDTH,
  DEFAULT_TILE,
  normalizeMagickPath,
} from "./contact-sheet.js";

describe("computeMontageGeometry", () => {
  it("should derive cell size from canvas and tile layout", () => {
    expect(computeMontageGeometry("4x4", 1280, 720, 4)).toBe("320x180+4+4");
  });

  it("should use defaults for standard triage canvas", () => {
    expect(computeMontageGeometry(DEFAULT_TILE, DEFAULT_CANVAS_WIDTH, DEFAULT_CANVAS_HEIGHT)).toBe(
      "320x180+4+4",
    );
  });
});

describe("normalizeMagickPath", () => {
  it("should convert backslashes to forward slashes", () => {
    expect(normalizeMagickPath("C:\\out\\sheet.jpg")).toBe("C:/out/sheet.jpg");
  });
});

describe("createContactSheet", () => {
  it("should invoke magick montage with 4x4 defaults", async () => {
    const spawnSync = vi.fn(() => ({ status: 0, stderr: Buffer.from("") }));
    const log = { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() };

    const result = await createContactSheet(
      ["/frames/a.png", "/frames/b.png"],
      "/out/sheet.jpg",
      {},
      { spawnSync, log },
    );

    expect(result).not.toBeNull();
    expect(result?.tile).toBe("4x4");
    expect(result?.frameCount).toBe(2);
    expect(spawnSync).toHaveBeenCalledWith(
      "magick",
      expect.arrayContaining([
        "montage",
        "/frames/a.png",
        "/frames/b.png",
        "-tile",
        "4x4",
        "-geometry",
        "320x180+4+4",
      ]),
      expect.objectContaining({ stdio: "pipe" }),
    );
  });

  it("should return null when magick fails", async () => {
    const spawnSync = vi.fn(() => ({ status: 1, stderr: Buffer.from("montage error") }));
    const log = { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() };

    const result = await createContactSheet(
      ["/frames/a.png"],
      "/out/sheet.jpg",
      {},
      { spawnSync, log },
    );

    expect(result).toBeNull();
    expect(log.warn).toHaveBeenCalled();
  });

  it("should return null for empty input", async () => {
    const spawnSync = vi.fn();
    const log = { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() };

    const result = await createContactSheet([], "/out/sheet.jpg", {}, { spawnSync, log });

    expect(result).toBeNull();
    expect(spawnSync).not.toHaveBeenCalled();
  });
});
