import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

import { writeStderr, writeStdout } from "./stderr.js";

/** Dependency inversion: filesystem side effects for one run. */
export interface RunFilesystem {
  ensureDirectory(path: string): void;
  readTextFile(path: string): string;
  writeTextFile(path: string, content: string): void;
  appendTextFile(path: string, line: string): void;
  appendRawTextFile(path: string, chunk: string): void;
}

/** Dependency inversion: console output (testable, no global console in core). */
export interface RunConsole {
  log(message: string): void;
  error(message: string): void;
}

/** Dependency inversion: process exit (testable run loop). */
export interface ProcessExit {
  exit(code: number): never;
}

/** Injected dependencies for {@link runAgentLoop} — default implementations use Node APIs. */
export interface RunLoopPorts {
  readonly filesystem: RunFilesystem;
  readonly console: RunConsole;
  readonly exit: ProcessExit;
}

export const defaultRunFilesystem: RunFilesystem = {
  ensureDirectory: (path) => {
    mkdirSync(path, { recursive: true });
  },
  readTextFile: (path) => readFileSync(path, "utf8"),
  writeTextFile: (path, content) => writeFileSync(path, content),
  appendTextFile: (path, line) => appendFileSync(path, `${line}\n`, "utf8"),
  appendRawTextFile: (path, chunk) => appendFileSync(path, chunk, "utf8"),
};

export const defaultRunConsole: RunConsole = {
  log: (message) => writeStdout(message),
  error: (message) => writeStderr(message),
};

export const defaultProcessExit: ProcessExit = {
  exit: (code) => process.exit(code),
};

export const defaultRunLoopPorts: RunLoopPorts = {
  filesystem: defaultRunFilesystem,
  console: defaultRunConsole,
  exit: defaultProcessExit,
};
