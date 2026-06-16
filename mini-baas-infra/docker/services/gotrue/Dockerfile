# syntax=docker/dockerfile:1
# File: docker/services/gotrue/Dockerfile
#
# 42-Inception self-build of Supabase Auth (GoTrue) v2.188.1 — built FROM Go
# source on a base WE control, NOT `FROM supabase/gotrue:*`.
#
# Replicates upstream's own build at tag v2.188.1
# (github.com/supabase/auth/blob/v2.188.1/Dockerfile): same toolchain image,
# same `make deps` + `make build` (ldflags inject utilities.Version), same
# `auth`→`gotrue` symlink, same migrations layout + GOTRUE_DB_MIGRATIONS_PATH,
# same minimal Alpine runtime + ca-certificates, same non-root user, same
# `CMD ["auth"]` (no subcommand = run migrations then serve on :9999).
#
# Final stage is Alpine (not distroless) on purpose: docker-compose.yml probes
# health with `wget -qO- http://localhost:9999/health`, which needs busybox
# wget — distroless has no wget/shell and would break that healthcheck.
#
#   docker build -t gr-gotrue:sb docker/services/gotrue
#   docker run --rm gr-gotrue:sb gotrue version      # -> v2.188.1

ARG AUTH_VERSION=2.188.1

# ── Builder ─────────────────────────────────────────────────────────────────
# Toolchain matches upstream's go.mod (go 1.25.8) and upstream's Dockerfile
# base. `make git` are upstream's build deps; the build is CGO-free + static.
FROM golang:1.25.8-alpine3.23 AS build
ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux

RUN apk add --no-cache make git

WORKDIR /go/src/github.com/supabase/auth

# Clone exactly the pinned release tag from source (an upstream source build —
# allowed input; this is NOT a ready-made image).
ARG AUTH_VERSION
RUN git clone --depth 1 --branch "v${AUTH_VERSION}" \
      https://github.com/supabase/auth.git .

# Prefetch deps (upstream's `make deps`), then build with upstream's own
# `make build`. RELEASE_VERSION=<tag> makes the Makefile stamp
# utilities.Version=v${AUTH_VERSION} (so `gotrue version` reports v2.188.1
# instead of the `git describe` / "vunspecified" fallback). Output binary is
# `auth` in the repo root, per the module name.
RUN --mount=type=cache,id=gomod-gotrue,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=gobuild-gotrue,target=/root/.cache/go-build,sharing=locked \
    make deps
RUN --mount=type=cache,id=gomod-gotrue,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=gobuild-gotrue,target=/root/.cache/go-build,sharing=locked \
    RELEASE_VERSION="${AUTH_VERSION}" make build

# ── Runtime ─────────────────────────────────────────────────────────────────
# Pinned slim Alpine WE control. ca-certificates: TLS to Postgres / SMTP /
# external OAuth providers (42, Google, GitHub). Non-root uid 1000 (upstream's
# `supabase` user). Keeps busybox wget for the compose healthcheck.
FROM alpine:3.21 AS runtime
RUN adduser -D -u 1000 supabase \
    && apk add --no-cache ca-certificates

# Binary + symlink (`gotrue` kept as a stable alias for tooling/compat).
COPY --from=build /go/src/github.com/supabase/auth/auth /usr/local/bin/auth
RUN ln -s /usr/local/bin/auth /usr/local/bin/gotrue

# Migrations shipped + pointed at, exactly like upstream — the binary auto-runs
# them on boot (root command = migrate then serve).
COPY --from=build /go/src/github.com/supabase/auth/migrations /usr/local/etc/auth/migrations/
ENV GOTRUE_DB_MIGRATIONS_PATH=/usr/local/etc/auth/migrations

EXPOSE 9999
USER supabase

# In-image healthcheck mirrors compose's contract; harmless if compose's own
# healthcheck overrides it. Alpine busybox provides wget.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:9999/health >/dev/null 2>&1 || exit 1

# No subcommand => `migrate` then `serve` on :9999 (reads GOTRUE_* env).
CMD ["auth"]
