# syntax=docker/dockerfile:1.7
# File: src/Dockerfile
# Unified NestJS multi-stage Dockerfile for all mini-BaaS apps.
# Build a specific app via: docker build --build-arg APP=adapter-registry src/

ARG NODE_VERSION=20
ARG APP=adapter-registry

# ─── Stage 1: Install ALL dependencies (dev + prod) ──────────────
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY --link package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
  npm ci --ignore-scripts --prefer-offline --no-audit --no-fund

# ─── Stage 2: Build the specific app ─────────────────────────────
FROM deps AS build
ARG APP
COPY --link tsconfig.json tsconfig.build.json nest-cli.json ./
COPY --link libs/ ./libs/
COPY --link apps/${APP}/ ./apps/${APP}/
RUN npx nest build ${APP}

# ─── Stage 3: Prune to production dependencies ───────────────────
FROM deps AS prod-deps
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
  npm prune --omit=dev --ignore-scripts --no-audit --no-fund

# ─── Stage 4: Production image ───────────────────────────────────
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-alpine AS runtime
ARG APP
ENV NODE_ENV=production \
  APP_NAME=${APP}

# Patch base OS packages (openssl/musl/zlib) to the latest alpine fixes — clears
# scanner HIGH/CRITICAL CVEs the node:alpine base ships with between base bumps.
RUN apk --no-cache upgrade

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app

# Runtime does not need npm/npx. Removing the bundled npm tree avoids shipping
# scanner-visible build tooling CVEs in production service images.
RUN rm -rf \
  /usr/local/bin/npm \
  /usr/local/bin/npx \
  /usr/local/lib/node_modules/npm

# Copy production-only deps without a second registry install.
COPY --from=prod-deps --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=prod-deps --chown=appuser:appgroup /app/package.json ./

# Copy compiled output
COPY --from=build --chown=appuser:appgroup --chmod=0555 /app/dist/ ./dist/

USER appuser

# Health probe: every NestJS app mounts /health/live via libs/health.
# PORT is injected at runtime by docker-compose (3010, 3020, ... per service).
# wget is included in the Alpine busybox base, no extra layer needed.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -qO- "http://localhost:${PORT:-3000}/health/live" >/dev/null 2>&1 || exit 1

# Default CMD — nest build outputs to dist/apps/<APP>/apps/<APP>/src/main.js
CMD ["sh", "-c", "node dist/apps/${APP_NAME}/apps/${APP_NAME}/src/main.js"]
