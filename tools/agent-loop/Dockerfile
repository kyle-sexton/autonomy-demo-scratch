# Per-iteration container for the agent-loop orchestrator.
#
# Thin image: no dotnet/node/MCP runtimes — see docs/adr/0013-agent-loop-thin-container-images.md + prompt-authoring.md § Per-pool capabilities.
#   IN IMAGE:  cursor-agent, curl, git, ripgrep, ca-certificates; network egress to cursor.com
#   NOT IN IMAGE (thin tracer): node, npm, dotnet, gh, python3, aspire CLI
#   jq: required by .claude/hooks/*.sh stdin parsing — included in thin image
#   IMPLICATION: agent can edit bind-mounted files; cannot run medley tests or MCP stdio servers
#                unless image grows or verification runs on host post-loop.
#
# The orchestrator bind-mounts a per-iteration workspace into /workspace and runs
# ONE fresh-context `cursor-agent` invocation against it (spawn -> work -> kill ->
# respawn). cursor-agent is a glibc binary — the official installer fails on
# Alpine/musl without libc6-compat — so Debian slim is the safe minimal base.
FROM debian:bookworm-slim@sha256:35ae959f6e83ffb465e7614d27b4fddd28288caa551fbca2798367567cce80d3

# cursor-agent runtime deps:
#   curl + ca-certificates -> run the installer over HTTPS
#   git                    -> the agent operates on a git workspace
#   ripgrep                -> cursor-agent's file-search backend
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

# Install the Cursor CLI (cursor-agent) via the official installer. It lands in
# ~/.local/bin; surface that on PATH for every later layer and at runtime.
# Official installer has no version pin — download to a file (not pipe-to-bash)
# and verify the installed binary version at build time. Bump ARG when upgrading.
ARG CURSOR_AGENT_VERSION=2026.06.04
RUN curl -fsSL https://cursor.com/install -o /tmp/cursor-install.sh \
  && bash /tmp/cursor-install.sh \
  && rm -f /tmp/cursor-install.sh \
  && ln -sf /root/.local/bin/cursor-agent /usr/local/bin/cursor-agent \
  && cursor-agent --version | grep -Fq "${CURSOR_AGENT_VERSION}"
ENV PATH="/root/.local/bin:/usr/local/bin:${PATH}"

# Optional Linux bind-mount ownership — build with host ids, runtime also uses `docker run --user`.
ARG AGENT_LOOP_UID=0
ARG AGENT_LOOP_GID=0
RUN if [ "${AGENT_LOOP_UID}" != "0" ] && [ "${AGENT_LOOP_GID}" != "0" ]; then \
      groupadd -g "${AGENT_LOOP_GID}" agentloop 2>/dev/null || true; \
      useradd -u "${AGENT_LOOP_UID}" -g "${AGENT_LOOP_GID}" -d /workspace agentloop 2>/dev/null || true; \
    fi

WORKDIR /workspace

# Build-time Tier-0 self-check: fail the image build if the binary did not land
# on PATH. `--version` needs no auth, runs no task, and incurs no spend.
RUN cursor-agent --version

# Deliberately no ENTRYPOINT/CMD that auto-runs the agent: the orchestrator
# supplies the exact `cursor-agent <flags> <prompt>` invocation per iteration,
# and that credentialed invocation is HARD-gated on spend-safety attestation.
