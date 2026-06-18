# syntax=docker/dockerfile:1.7
# File: docker/services/pg-meta/Dockerfile
#
# 42-Inception: build supabase/postgres-meta FROM SOURCE on our own slim base —
# we do NOT pull the ready-made supabase/postgres-meta application image.
# Only node:20-slim (a lightweight Debian base we control) is pulled.
#
# Why node:20-slim and not node:20-alpine: postgres-meta depends on libpg-query,
# a native node addon (queryparser.node) that has NO musl prebuilt and whose
# bundled libpg_query C parser does NOT compile on Alpine's GCC 14
# (-Wincompatible-pointer-types is a hard error there).  This makes it
# effectively MUSL-INCOMPATIBLE, so per the slimming rule we use debian-slim.
# node:20 -> node:20-slim is exactly the upstream build shape; we just add the
# from-source clone, npm-prune, and npm-stripping that the slim pattern wants.
#
# Multi-stage:
#   deps  -> shallow-clone source tag + npm clean-install (all deps, builds NIF)
#   build -> npm run build, then prune to prod deps
#   runtime (node:20-slim, npm stripped) -> dist + prod node_modules only.

ARG NODE_VERSION=20
ARG PG_META_VERSION=v0.91.0

# ─── Stage 1: clone source + install ALL deps (dev + prod) ───────
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-slim AS deps
ARG PG_META_VERSION
# git: shallow-clone the tag.  python3/make/g++: node-gyp compiles libpg-query's
# bundled C parser from source.  All of this toolchain lives ONLY in the build
# stages and never reaches the runtime image.
RUN apt-get update \
  && apt-get install -y --no-install-recommends git python3 make g++ ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone --depth 1 --branch "${PG_META_VERSION}" \
      https://github.com/supabase/postgres-meta.git . \
  && rm -rf .git
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
  npm clean-install --no-audit --no-fund

# ─── Stage 2: build the app ──────────────────────────────────────
FROM deps AS build
RUN npm run build

# ─── Stage 3: prune to production dependencies ───────────────────
FROM build AS prod-deps
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
  npm prune --omit=dev --no-audit --no-fund

# ─── Stage 4: production runtime ─────────────────────────────────
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-slim AS runtime
ENV NODE_ENV=production \
    PG_META_PORT=8080
WORKDIR /app

# ca-certificates only (upstream installs the same); then strip npm/npx so the
# runtime ships no build-tool CVE surface (mirrors src/Dockerfile).
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/* \
  && rm -rf /usr/local/bin/npm /usr/local/bin/npx /usr/local/lib/node_modules/npm \
  # Docs/man/info/locale are never read at runtime (node server only).
  && rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/groff \
            /usr/share/lintian /usr/share/linda /usr/share/locale/*

# Non-root: keep parity with the compose `USER 1001`. node:*-slim ships a
# `node` user (uid 1000); add a dedicated uid-1001 user to match.
RUN groupadd -g 1001 appgroup && useradd -u 1001 -g appgroup -M -s /usr/sbin/nologin appuser

COPY --from=prod-deps --chown=1001:1001 /app/node_modules ./node_modules
COPY --from=prod-deps --chown=1001:1001 /app/package.json ./package.json
COPY --from=build     --chown=1001:1001 /app/dist ./dist

USER 1001:1001
EXPOSE 8080

# compose's healthcheck (node fetch on /health) is authoritative at runtime;
# this is a build-image fallback. node:*-slim has no wget/curl, so use node.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/health').then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))"

# Upstream entrypoint.
CMD ["node", "dist/server/server.js"]
