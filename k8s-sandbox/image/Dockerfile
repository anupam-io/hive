# Generalized coding-agent image: Claude Code + git + gh + jq.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates curl wget gnupg jq \
      build-essential python3 \
      unzip ripgrep \
      gettext-base \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# bun — chain-monitor's package manager (`bun install`, `bun run build`).
# Install to a system path so it's on PATH for all users including node (uid 1000).
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash \
 && ln -sf /usr/local/bin/bun /usr/local/bin/bunx \
 && /usr/local/bin/bun --version

# Globally-available TypeScript so workers can `tsc --noEmit` even outside a
# workspace that has it pinned. Real type-check still uses the project's
# version after `bun install`; this is the safety net the workers were
# missing. claude-code is the agent runtime itself. Playwright + chromium
# (~1.18GB) are NOT here — only the qa role needs a browser, so they live in
# the web-qa-agent image (Dockerfile.qa, FROM this base). Workers/reviewers
# stay lean.
RUN npm install -g typescript @anthropic-ai/claude-code \
 && npm cache clean --force

WORKDIR /workspace
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY agent.sh /usr/local/bin/agent
COPY qa-agent.sh /usr/local/bin/qa-agent
COPY qa-capture.mjs /usr/local/bin/qa-capture.mjs
COPY templates/ /opt/hive/templates/
COPY skills/ /opt/hive/skills/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/agent /usr/local/bin/qa-agent

# Claude Code refuses --dangerously-skip-permissions as root. node:* images
# ship with a `node` user (uid 1000) — use it.
RUN mkdir -p /workspace /logs /home/node/.claude \
 && chown -R node:node /workspace /logs /home/node
USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
