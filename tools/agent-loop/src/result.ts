/**
 * Railway-oriented result for expected orchestrator failures.
 * Parallels {@link Platform.Core.Results.Result} — explicit success/failure, no exceptions for control flow.
 */

export interface LoopError {
  readonly exitCode: number;
  readonly message: string;
}

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: LoopError };

export function success<T>(value: T): Result<T> {
  return { ok: true, value };
}

export function successVoid(): Result<void> {
  return { ok: true, value: undefined };
}

export function failure(exitCode: number, message: string): Result<never> {
  return { ok: false, error: { exitCode, message } };
}

/** Branch without throwing — mirrors .NET {@code Result.Match}. */
export function matchResult<T, U>(
  result: Result<T>,
  onSuccess: (value: T) => U,
  onFailure: (error: LoopError) => U,
): U {
  return result.ok ? onSuccess(result.value) : onFailure(result.error);
}
