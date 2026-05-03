# syntax=docker/dockerfile:1
# File: src/Dockerfile
# Unified NestJS multi-stage Dockerfile for all mini-BaaS apps.
# Build a specific app via: docker build --build-arg APP=adapter-registry src/

ARG NODE_VERSION=20
ARG APP=adapter-registry

# ─── Stage 1: Install ALL dependencies (dev + prod) ──────────────
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY --link package.json package-lock.json ./
RUN npm ci

# ─── Stage 2: Build the specific app ─────────────────────────────
FROM deps AS build
ARG APP
COPY --link tsconfig.json tsconfig.build.json nest-cli.json ./
COPY --link libs/ ./libs/
COPY --link apps/ ./apps/
RUN npx nest build ${APP}

# ─── Stage 3: Production image ───────────────────────────────────
FROM node:${NODE_VERSION}-alpine AS runtime
ARG APP
ENV NODE_ENV=production \
  APP_NAME=${APP}

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app

# Install production-only deps
COPY --link package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copy compiled output
COPY --from=build --chown=appuser:appgroup --chmod=0555 /app/dist/ ./dist/

USER appuser

# Default CMD — nest build outputs to dist/apps/<APP>/apps/<APP>/src/main.js
CMD ["sh", "-c", "node dist/apps/${APP_NAME}/apps/${APP_NAME}/src/main.js"]
