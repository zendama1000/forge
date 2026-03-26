FROM node:22-bookworm

# System dependencies
RUN apt-get update && apt-get install -y \
    jq \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Claude CLI
RUN npm install -g @anthropic-ai/claude-code

# Non-root user (Claude CLI blocks --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash -u 1000 forge || true \
    && mkdir -p /workspace /home/forge \
    && chown -R 1000:1000 /workspace /home/forge

WORKDIR /workspace

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

USER forge
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["bash"]
