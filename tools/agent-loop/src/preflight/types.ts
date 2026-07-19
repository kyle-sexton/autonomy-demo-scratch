import type { Result } from "../result.js";

/** Per-CLI prompt validation run before the iteration loop. */
export type IterationPreflightChecker = (prompt: string) => Result<void>;
