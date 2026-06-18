# syntax=docker/dockerfile:1.7
# Multi-stage build for Vite Gourmand monolith deployment to Fly.io
# Frontend (Vite) is built and embedded into the NestJS backend, which
# serves /api/* + the SPA from /app/public on a single port (8080).

ARG NODE_VERSION=22-alpine

# ============================================================================
# Stage 1 — Build the frontend (React + Vite)
# ============================================================================
FROM node:${NODE_VERSION} AS frontend-build
WORKDIR /build/View

COPY View/package.json View/package-lock.json* ./
RUN npm ci --no-audit --no-fund

COPY View/ ./

# Vite bakes VITE_* env vars at build time. Empty VITE_API_URL → relative
# requests, which are served by the same NestJS instance.
ENV VITE_API_URL="" \
    VITE_BACKEND_URL="" \
    VITE_PUBLIC_SITE_URL="https://vite-gourmand-withered-glitter-7902.fly.dev"
RUN npm run build
# Output: /build/View/dist

# ============================================================================
# Stage 2 — Build the backend (NestJS + Prisma)
# ============================================================================
FROM node:${NODE_VERSION} AS backend-build
WORKDIR /build/Back

# Native build deps for bcrypt
RUN apk add --no-cache python3 make g++ libc6-compat openssl

COPY Back/package.json Back/package-lock.json* ./
RUN npm ci --no-audit --no-fund

COPY Back/ ./

# Generate the Prisma client (schema output → Back/generated/prisma)
RUN npx prisma generate --schema=src/Model/prisma/schema.prisma

# Compile TypeScript (the script also copies src/i18n into dist/src)
RUN npm run build

# Strip dev dependencies to shrink the runtime layer
RUN npm prune --omit=dev

# ============================================================================
# Stage 3 — Runtime
# ============================================================================
FROM node:${NODE_VERSION} AS runtime

# libc6-compat for prebuilt native binaries; tini for proper PID 1 signal handling;
# openssl is required by Prisma's query engine on Alpine.
RUN apk add --no-cache libc6-compat tini openssl

WORKDIR /app

ENV NODE_ENV=production \
    PORT=8080

# Backend production node_modules
COPY --from=backend-build /build/Back/node_modules ./node_modules

# Compiled backend (dist/src/main.js is the entry; src/i18n is bundled in)
COPY --from=backend-build /build/Back/dist ./dist
COPY --from=backend-build /build/Back/package.json ./package.json

# Generated Prisma client
COPY --from=backend-build /build/Back/generated ./generated

# Prisma schema (kept around for future migrations / introspection)
COPY --from=backend-build /build/Back/src/Model/prisma ./prisma

# Built frontend — main.ts in production resolves __dirname/../../public,
# which from /app/dist/src is /app/public.
COPY --from=frontend-build /build/View/dist ./public

# Non-root runtime user
RUN addgroup -g 1001 -S nodejs \
 && adduser -S nestjs -u 1001 \
 && chown -R nestjs:nodejs /app
USER nestjs

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/src/main.js"]
