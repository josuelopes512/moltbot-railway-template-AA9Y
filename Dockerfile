# Build clawdbot from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS clawdbot-build

# Dependencies needed for clawdbot build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (clawdbot build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /clawdbot

# Pin to a known ref (tag/branch). If it doesn't exist, fall back to main.
ARG CLAWDBOT_GIT_REF=main
RUN git clone --depth 1 --branch "${CLAWDBOT_GIT_REF}" https://github.com/clawdbot/clawdbot.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Scope this narrowly to avoid surprising dependency mutations.
RUN set -eux; \
  for f in \
    ./extensions/memory-core/package.json \
    ./extensions/googlechat/package.json \
  ; do \
    if [ -f "$f" ]; then \
      sed -i -E 's/"clawdbot"[[:space:]]*:[[:space:]]*">=[^"]+"/"clawdbot": "*"/g' "$f"; \
      sed -i -E 's/"moltbot"[[:space:]]*:[[:space:]]*">=[^"]+"/"moltbot": "*"/g' "$f"; \
    fi; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV CLAWDBOT_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    nano \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev \
  && npm install -g pm2 \
  && npm cache clean --force

# Copy built clawdbot
COPY --from=clawdbot-build /clawdbot /clawdbot

# Provide a clawdbot executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /clawdbot/dist/entry.js "$@"' > /usr/local/bin/clawdbot \
  && chmod +x /usr/local/bin/clawdbot

COPY src ./src

# PM2 ecosystem (moltbolt gateway)
RUN printf '%s\n' \
'module.exports = {' \
'  apps: [' \
'    {' \
'      name: "moltbolt-gateway",' \
'      script: "clawdbot",' \
'      args:  ["gateway", "run", "--port", "18789", "--bind", "lan"],' \
'      exec_interpreter: true,' \
'      autorestart: true,' \
'      restart_delay: 5000,' \
'      time: true,' \
'    }' \
'  ]' \
'};' \
> /app/ecosystem.config.cjs

# Entrypoint: mantém CMD como node, mas inicia via PM2 automaticamente.
# (Intercepta o CMD padrão e executa o processo PM2 "moltbolt-gateway")
RUN printf '%s\n' \
'#!/usr/bin/env bash' \
'set -e' \
'' \
'# If started with the default CMD, run under PM2 automatically.' \
'if [ "$1" = "node" ] && [ "$2" = "src/server.js" ]; then' \
'  exec pm2-runtime /app/ecosystem.config.cjs --only moltbolt-gateway' \
'fi' \
'' \
'# Otherwise, run the provided command.' \
'exec "$@"' \
> /usr/local/bin/docker-entrypoint.sh \
  && chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Create and declare persistent volumes for clawdbot state
RUN mkdir -p /home/node/.clawdbot /home/node/clawd \
  && chown -R node:node /home/node/.clawdbot /home/node/clawd

VOLUME ["/home/node/.clawdbot", "/home/node/clawd"]

ENV PORT=8080
EXPOSE 8080 18789

# Mantido como você pediu
CMD ["node", "src/server.js"]
