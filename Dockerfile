FROM node:22-bookworm AS clawdbot-build

SHELL ["/bin/bash", "-lc"]

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
RUN git clone --depth 1 --branch "${CLAWDBOT_GIT_REF}" https://github.com/josuelopes512/moltbot.git .

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

SHELL ["/bin/bash", "-lc"]

ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    nano \
    chromium \
    jq \
    curl \
  && rm -rf /var/lib/apt/lists/*

# Install Tailscale (note: /dev/net/tun + NET_ADMIN must be granted at *runtime*, not build time)
RUN curl -fsSL https://tailscale.com/install.sh | bash

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev \
  && npm install -g pm2 \
  && npm install -g @google/gemini-cli \
  && npm cache clean --force

# Copy built clawdbot
COPY --from=clawdbot-build /clawdbot /clawdbot

# Provide a clawdbot executable
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exec node /clawdbot/dist/entry.js "$@"' \
  > /usr/local/bin/clawdbot \
 && chmod +x /usr/local/bin/clawdbot

COPY src ./src

# PM2 ecosystem (moltbolt gateway)
RUN cat > /app/ecosystem.config.cjs <<'EOF'
module.exports = {
  apps: [
    {
      name: "moltbolt-gateway",
      script: "clawdbot",
      args: ["gateway", "run", "--port", "18789", "--bind", "lan"],
      interpreter: "bash",
      autorestart: true,
      restart_delay: 5000,
      time: true,
    }
  ]
};
EOF

# Entrypoint: inicia Tailscale (se configurado) e depois PM2/comando
RUN cat > /usr/local/bin/docker-entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -e

# Criar diretórios necessários para o Tailscale
mkdir -p /var/run/tailscale /var/lib/tailscale

# Iniciar tailscaled em background (se NET_ADMIN disponível)
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  echo "Starting Tailscale daemon..."
  tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
  sleep 2

  echo "Authenticating Tailscale..."
  tailscale --socket=/var/run/tailscale/tailscaled.sock up \
    --authkey="${TAILSCALE_AUTHKEY}" \
    --hostname="${TAILSCALE_HOSTNAME:-moltbot-container}" \
    --accept-dns=false \
    ${TAILSCALE_EXTRA_ARGS:-}

  echo "Tailscale connected!"
  tailscale --socket=/var/run/tailscale/tailscaled.sock status

  # CORREÇÃO: configurar Exit Node via `tailscale up` (não `tailscale set`)
  # Motivo: `tailscale set --exit-node=...` pode deixar RouteAll=false em alguns cenários,
  # fazendo com que o tráfego de internet NÃO seja roteado pelo exit node.
  if [ -n "${TAILSCALE_EXIT_NODE:-}" ]; then
    echo "Configuring exit node (full-tunnel): ${TAILSCALE_EXIT_NODE}..."

    # Re-aplica o up incluindo o exit node. Precisamos re-mencionar os flags não-default,
    # senão o tailscale retorna erro.
    tailscale --socket=/var/run/tailscale/tailscaled.sock up \
      --authkey="${TAILSCALE_AUTHKEY}" \
      --hostname="${TAILSCALE_HOSTNAME:-moltbot-container}" \
      --accept-dns=false \
      --exit-node="${TAILSCALE_EXIT_NODE}" \
      --exit-node-allow-lan-access=true \
      ${TAILSCALE_EXTRA_ARGS:-}

    echo "Exit node configured!"
    sleep 1

    # Verificar IP público (IPv4/IPv6) para facilitar diagnóstico
    echo "Public IP (v4):"; curl -4 -s https://ifconfig.me/ip || echo "Failed to get public IPv4"
    echo ""
    echo "Public IP (v6):"; curl -6 -s https://ifconfig.me/ip || echo "Failed to get public IPv6"
    echo ""
  fi
fi

# If started with the default CMD, run under PM2 automatically.
if [ "${1:-}" = "node" ] && [ "${2:-}" = "src/server.js" ]; then
  exec pm2-runtime /app/ecosystem.config.cjs --only moltbolt-gateway
fi

# Otherwise, run the provided command.
exec "$@"
EOF

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Create and declare persistent volumes for clawdbot state
RUN mkdir -p /root/clawd /data/.clawdbot
VOLUME ["/root/clawd", "/data/.clawdbot"]

ENV PORT=8080

EXPOSE 8080 18789

# Mantido como você pediu
CMD ["node", "src/server.js"]