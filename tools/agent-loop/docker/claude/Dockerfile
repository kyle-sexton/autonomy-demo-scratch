# Claude Code CLI — thin tracer image for agent-loop `claude-default` pool.
#
# Build: cd tools/agent-loop && docker build -t agent-loop-claude:thin -f docker/claude/Dockerfile .
# Auth: forward CLAUDE_CODE_OAUTH_TOKEN (subscription OAuth) — never ANTHROPIC_API_KEY.
# Hooks: native medley .claude/hooks require jq (see docs/adr/0013-agent-loop-thin-container-images.md).
FROM debian:bookworm-slim@sha256:35ae959f6e83ffb465e7614d27b4fddd28288caa551fbca2798367567cce80d3

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    bubblewrap \
    ca-certificates \
    curl \
    git \
    jq \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CLI_VERSION=2.1.178
ENV DISABLE_AUTOUPDATER=1
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
  && bash /tmp/claude-install.sh "${CLAUDE_CLI_VERSION}" \
  && rm -f /tmp/claude-install.sh \
  && install -m 0755 /root/.local/bin/claude /usr/local/bin/claude \
  && claude --version >/dev/null
ENV PATH="/usr/local/bin:${PATH}"

ARG AGENT_LOOP_UID=1000
ARG AGENT_LOOP_GID=1000
RUN if [ "${AGENT_LOOP_UID}" != "0" ] && [ "${AGENT_LOOP_GID}" != "0" ]; then \
      groupadd -g "${AGENT_LOOP_GID}" agentloop 2>/dev/null || true; \
      useradd -u "${AGENT_LOOP_UID}" -g "${AGENT_LOOP_GID}" -d /workspace agentloop 2>/dev/null || true; \
    fi

WORKDIR /workspace

RUN claude --version | grep -Fq "${CLAUDE_CLI_VERSION}" && command -v jq >/dev/null
