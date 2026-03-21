FROM node:22-bookworm

# System dependencies
RUN apt-get update && apt-get install -y \
    jq \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Claude CLI
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /workspace

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["bash"]
