# syntax=docker/dockerfile:1
# File: src/Dockerfile
# Unified NestJS multi-stage Dockerfile for all mini-BaaS apps.
# Build a specific app via: docker build --build-arg APP=adapter-registry src/

ARG NODE_VERSION=20
ARG APP=adapter-registry

FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
COPY --link package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

FROM deps AS build
ARG APP
COPY --link tsconfig.json tsconfig.build.json nest-cli.json ./
COPY --link libs/ ./libs/
COPY --link apps/ ./apps/
RUN pnpm exec nest build ${APP}

FROM node:${NODE_VERSION}-alpine AS runtime
ARG APP
ENV NODE_ENV=production \
  APP_NAME=${APP}

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
ENV PNPM_HOME="/pnpm"

ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
COPY --link package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile && pnpm store prune

COPY --from=build --chown=appuser:appgroup /app/dist/ ./dist/

USER appuser

CMD ["sh", "-c", "node dist/apps/${APP_NAME}/apps/${APP_NAME}/src/main.js"]
