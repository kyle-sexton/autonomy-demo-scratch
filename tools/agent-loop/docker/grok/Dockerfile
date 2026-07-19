# Grok Build CLI — thin tracer image for agent-loop multi-CLI pools.
#
# Build: docker build -t agent-loop-grok:thin -f docker/grok/Dockerfile .
# Auth: bind-mount ~/.grok/auth.json — never XAI_API_KEY for subscription runs.
FROM debian:bookworm-slim@sha256:35ae959f6e83ffb465e7614d27b4fddd28288caa551fbca2798367567cce80d3

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

# Grok CLI via official install script — upstream installer has no version pin; smoke-check only.
ENV GROK_INSTALL_DIR=/root/.grok
ENV PATH="${GROK_INSTALL_DIR}/bin:${PATH}"
RUN curl -fsSL https://x.ai/cli/install.sh | bash \
  && grok --no-auto-update --version | grep -q .

ENV HOME=/workspace

ARG AGENT_LOOP_UID=0
ARG AGENT_LOOP_GID=0
RUN if [ "${AGENT_LOOP_UID}" != "0" ] && [ "${AGENT_LOOP_GID}" != "0" ]; then \
      groupadd -g "${AGENT_LOOP_GID}" agentloop 2>/dev/null || true; \
      useradd -u "${AGENT_LOOP_UID}" -g "${AGENT_LOOP_GID}" -d /workspace agentloop 2>/dev/null || true; \
    fi

WORKDIR /workspace

RUN grok --no-auto-update --help | head -5
