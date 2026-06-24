# ============================================
# Vite Gourmand - Development Container
# ============================================

FROM node:22-alpine

RUN apk add --no-cache \
    bash \
    curl \
    g++ \
    git \
    jq \
    libc6-compat \
    make \
    openssl \
    procps \
    psmisc \
    python3

WORKDIR /app

ENV NPM_CONFIG_LOGLEVEL=warn
ENV NPM_CONFIG_CACHE=/app/.npm-cache
ENV NPM_CONFIG_FUND=false
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

RUN npm install -g --ignore-scripts typescript@6.0.3 @nestjs/cli@11.0.21 prisma@7.8.0 2>/dev/null

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD node -v >/dev/null || exit 1

CMD ["tail", "-f", "/dev/null"]