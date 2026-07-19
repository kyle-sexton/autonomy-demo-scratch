# OpenAI Codex CLI — thin tracer image for agent-loop multi-CLI pools.
#
# Build: docker build -t agent-loop-codex:thin -f docker/codex/Dockerfile .
# Auth: bind-mount ~/.codex/auth.json — never OPENAI_API_KEY / CODEX_API_KEY.
FROM debian:bookworm-slim@sha256:35ae959f6e83ffb465e7614d27b4fddd28288caa551fbca2798367567cce80d3

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

# Codex CLI via npm — pin version and verify at build time.
ARG CODEX_CLI_VERSION=0.139.0
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install -g "@openai/codex@${CODEX_CLI_VERSION}" \
  && rm -rf /var/lib/apt/lists/*
ENV HOME=/workspace

ARG AGENT_LOOP_UID=0
ARG AGENT_LOOP_GID=0
RUN if [ "${AGENT_LOOP_UID}" != "0" ] && [ "${AGENT_LOOP_GID}" != "0" ]; then \
      groupadd -g "${AGENT_LOOP_GID}" agentloop 2>/dev/null || true; \
      useradd -u "${AGENT_LOOP_UID}" -g "${AGENT_LOOP_GID}" -d /workspace agentloop 2>/dev/null || true; \
    fi

WORKDIR /workspace

RUN codex --version | grep -Fq "${CODEX_CLI_VERSION}"
