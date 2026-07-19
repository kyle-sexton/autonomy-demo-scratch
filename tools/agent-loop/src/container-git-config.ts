/**
 * Container git env overrides for bind-mounted workspaces.
 *
 * Linux git inside Docker defaults to core.fileMode=true. On Windows host
 * bind mounts, NTFS cannot represent the index exec bit in the working tree,
 * so fileMode=true on the shared `.git/config` drowns the host in phantom
 * 100755→100644 diffs.
 *
 * GIT_CONFIG_* pairs override config files for the container process only
 * (git-config ENVIRONMENT). Safe on Linux/macOS hosts — does not change host
 * repo policy. Host repair: {@link repairHostGitConfigLeaks} + bootstrap on Windows.
 *
 * GIT_CONFIG_NOSYSTEM skips image system config — avoids /etc/gitconfig bleed.
 */

const CONTAINER_GIT_CONFIG_OVERRIDES: ReadonlyArray<{
  readonly key: string;
  readonly value: string;
}> = [
  { key: "core.fileMode", value: "false" },
  { key: "core.autocrlf", value: "false" },
];

/** Build indexed GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n env block plus isolation flags. */
export function buildContainerGitConfigEnv(): Readonly<Record<string, string>> {
  const env: Record<string, string> = {
    GIT_CONFIG_NOSYSTEM: "1",
  };
  const count = CONTAINER_GIT_CONFIG_OVERRIDES.length;
  env["GIT_CONFIG_COUNT"] = String(count);
  for (let index = 0; index < count; index++) {
    const entry = CONTAINER_GIT_CONFIG_OVERRIDES[index];
    if (entry === undefined) {
      continue;
    }
    env[`GIT_CONFIG_KEY_${index}`] = entry.key;
    env[`GIT_CONFIG_VALUE_${index}`] = entry.value;
  }
  return env;
}
