/** Container path for bind-mounted Grok subscription auth (outside workspace — avoids repo pollution). */
export const GROK_AUTH_CONTAINER_PATH = "/var/grok-home/auth.json";

/** Grok CLI home inside the container — not under /workspace (sessions/config must not litter the bind mount). */
export const GROK_HOME_CONTAINER = "/var/grok-home";
