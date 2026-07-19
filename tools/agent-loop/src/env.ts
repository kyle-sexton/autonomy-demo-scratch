import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** Gitignored local secrets file (dotenv convention — same default as the `dotenv` npm package). */
export const ENV_FILENAME = ".env";

export const ENV_EXAMPLE_FILENAME = ".env.example";

export type EnvAssignment = { key: string; value: string };

/**
 * Parse `KEY=VALUE` lines from a dotenv-style file body. Skips blank lines and
 * `#` comments. Strips optional matching single/double quotes around values.
 * Does not mutate `process.env`.
 */
export function parseEnvAssignments(content: string): EnvAssignment[] {
  const assignments: EnvAssignment[] = [];

  for (const rawLine of content.split("\n")) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith("#")) {
      continue;
    }

    const equalsIndex = line.indexOf("=");
    if (equalsIndex <= 0) {
      continue;
    }

    const key = line.slice(0, equalsIndex).trim();
    if (key.length === 0) {
      continue;
    }

    let value = line.slice(equalsIndex + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    assignments.push({ key, value });
  }

  return assignments;
}

/**
 * Set assignment keys on `env` only when the key is absent or empty. Returns the
 * keys that were written. Existing non-empty values (typically OS env) always win.
 */
export function applyEnvAssignments(
  assignments: readonly EnvAssignment[],
  env: NodeJS.ProcessEnv,
): string[] {
  const applied: string[] = [];

  for (const { key, value } of assignments) {
    const existing = env[key];
    if (existing !== undefined && existing !== "") {
      continue;
    }
    env[key] = value;
    applied.push(key);
  }

  return applied;
}

/**
 * Load gitignored `{projectRoot}/.env` when present. OS / parent-process env wins
 * for any key already set. Matches the usual dotenv default (single `.env` file).
 */
export function loadProjectEnv(
  projectRoot: string,
  env: NodeJS.ProcessEnv = process.env,
): string[] {
  const path = join(projectRoot, ENV_FILENAME);
  if (!existsSync(path)) {
    return [];
  }

  const content = readFileSync(path, "utf8");
  return applyEnvAssignments(parseEnvAssignments(content), env);
}

/**
 * Return the env var names that an invocation requires but are missing or empty
 * in the given environment. An empty string counts as missing: docker `-e NAME`
 * (name-only) would forward an empty value, and cursor-agent in a non-TTY
 * `--print` container with no usable key would block on auth rather than fail
 * fast. The orchestrator uses this to refuse a launch BEFORE any `docker run`.
 */
export function missingEnvVars(
  required: readonly string[],
  env: Readonly<Record<string, string | undefined>>,
): string[] {
  return required.filter((name) => {
    const value = env[name];
    return value === undefined || value === "";
  });
}

/** Actionable setup text when required credential env vars are absent. */
export function credentialSetupHint(projectRoot: string, missing: readonly string[]): string {
  const examplePath = join(projectRoot, ENV_EXAMPLE_FILENAME);
  const envPath = join(projectRoot, ENV_FILENAME);
  return (
    `Missing: ${missing.join(", ")}. Set via OS environment (Windows: setx; macOS/Linux: shell profile export) ` +
    `or copy ${examplePath} to ${envPath} and fill in values. OS env wins when set. ` +
    `See README.md "First-time setup".`
  );
}
