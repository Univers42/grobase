# syntax=docker/dockerfile:1.7
# File: docker/services/studio/Dockerfile
#
# 42-Inception: build supabase/studio FROM SOURCE on our own slim base — we do
# NOT pull the ready-made supabase/studio application image.  Only node:22-slim
# (the lightweight Debian base upstream itself uses; Studio's Next.js + native
# libpg build is effectively MUSL-INCOMPATIBLE, so debian-slim is the slim
# choice here) is pulled.
#
# Studio is a Next.js app inside the supabase TURBO MONOREPO.  Upstream builds
# it with `docker build . -f apps/studio/Dockerfile` from the monorepo root
# (COPY . . then `turbo prune studio`).  To keep this Dockerfile self-contained
# we shallow-fetch the monorepo at the EXACT pinned commit and run the same
# pipeline: turbo-prune -> pnpm install -> next build -> copy the Next.js
# standalone output into a minimal runtime.  Stages/Next-standalone handling
# mirror apps/studio/Dockerfile (master) 1:1.
#
# Pin = the compose image tag supabase/studio:2026.03.30-sha-12a43e5.
#
# NOTE (best-effort / CI-validate): this is a full Next.js production build of a
# large monorepo (multi-GB clone + long pnpm install + next build).  It is
# correct and reproducible, but heavy; Studio is OPTIONAL (control-plane/studio
# profile only), so if a local build is too slow it is validated in CI.

ARG NODE_VERSION=22
ARG STUDIO_SHA=12a43e5abac85754837b450339d2f5bd113d8d42
ARG PNPM_VERSION=10.24.0
ARG TURBO_VERSION=2.9.14

# ─── base: node:22-slim + pnpm + the build toolchain (upstream parity) ───
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-slim AS base
ENV PNPM_HOME="/pnpm" \
    PATH="/pnpm:$PATH"
# git: fetch the monorepo + build libpg.  python3/build-essential: native deps.
RUN apt-get update -qq \
  && apt-get install -y --no-install-recommends git python3 ca-certificates build-essential \
  && rm -rf /var/lib/apt/lists/* \
  && update-ca-certificates
ARG PNPM_VERSION
RUN npm install -g pnpm@${PNPM_VERSION}
WORKDIR /app

# ─── source: shallow-fetch the monorepo at the exact pinned commit ───
# (git clone cannot take a raw sha as --branch, so init + fetch the sha.)
FROM base AS source
ARG STUDIO_SHA
RUN git init -q . \
  && git remote add origin https://github.com/supabase/supabase.git \
  && git fetch --depth 1 origin "${STUDIO_SHA}" \
  && git checkout -q FETCH_HEAD \
  && rm -rf .git

# ─── turbo: prune the monorepo down to just what `studio` needs ───
FROM base AS turbo
ARG TURBO_VERSION
COPY --from=source /app/ ./
RUN pnpm dlx turbo@${TURBO_VERSION} prune studio --docker

# ─── deps: install dependencies from the pruned lockfile ───
FROM base AS deps
COPY --from=turbo /app/out/json ./
COPY --from=turbo /app/out/pnpm-lock.yaml ./
# patches/ is referenced by the root pnpm config; copy it if present.
COPY --from=source /app/patches/ ./patches/
RUN pnpm install --frozen-lockfile

# ─── dev: add full (uncompiled) source ───
FROM deps AS dev
COPY --from=turbo /app/out/full ./

# ─── builder: compile Next.js (produces .next/standalone) ───
FROM dev AS builder
RUN pnpm --filter studio exec next build

# ─── production: minimal runtime — Next.js standalone output only ───
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-slim AS production
ENV NODE_ENV=production \
    HOSTNAME=0.0.0.0 \
    PORT=3000
WORKDIR /app
# Non-root parity with the compose `USER 1001`. Also strip docs/man/info/locale
# the base ships — never read at runtime (Next.js standalone node server only).
RUN groupadd -g 1001 appgroup \
  && useradd -u 1001 -g appgroup -M -s /usr/sbin/nologin appuser \
  && rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/groff \
            /usr/share/lintian /usr/share/linda /usr/share/locale/* \
            /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
COPY --from=builder --chown=1001:1001 /app/apps/studio/public ./apps/studio/public
COPY --from=builder --chown=1001:1001 /app/apps/studio/.next/standalone ./
COPY --from=builder --chown=1001:1001 /app/apps/studio/.next/static ./apps/studio/.next/static
USER 1001:1001
EXPOSE 3000
# Mirrors upstream; compose's own healthcheck (node fetch /api/profile) is
# authoritative at runtime.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000').then(()=>process.exit(0)).catch(()=>process.exit(1))"
CMD ["node", "apps/studio/server.js"]
