/** Container path for bind-mounted Codex subscription auth (outside workspace — avoids repo pollution). */
export const CODEX_AUTH_CONTAINER_PATH = "/var/codex-home/auth.json";

/** Codex CLI home inside the container — not under /workspace (sessions/config must not litter the bind mount). */
export const CODEX_HOME_CONTAINER = "/var/codex-home";
