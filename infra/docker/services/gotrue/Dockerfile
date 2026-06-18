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
# same non-root user, same `CMD ["auth"]` (no subcommand = run migrations then
# serve on :9999).
#
# Final stage is SCRATCH (not Alpine, not distroless). The `auth` binary is
# CGO-free + fully statically linked (verified: `ldd` reports "Not a valid
# dynamic program"), so it needs no libc/loader and runs on scratch directly —
# dropping the ~8 MB Alpine layer + its shell/apk attack surface. The three
# things gotrue actually needs at runtime are carried in explicitly:
#   • ca-certificates → gotrue makes OUTBOUND TLS to Postgres / SMTP / external
#     OAuth providers (42, Google, GitHub), so it MUST have a CA bundle; we copy
#     just /etc/ssl/certs/ca-certificates.crt (the file, not the apk package);
#   • the migrations dir + GOTRUE_DB_MIGRATIONS_PATH → the binary auto-runs
#     migrations on boot (root command = migrate then serve);
#   • a static busybox → docker-compose.yml probes health with
#     `wget -qO- http://localhost:9999/health`; scratch has no shell, so we ship
#     ONE static busybox to provide `wget` (same pattern as
#     docker/services/postgrest/Dockerfile).
# scratch has no /etc/passwd, so the non-root user is numeric (uid 1000, the
# uid of upstream's `supabase` user). The `auth`/`gotrue` pair is staged as a
# symlink in the builder and COPY'd (scratch can't `RUN ln -s`).
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
    make deps \
 && RELEASE_VERSION="${AUTH_VERSION}" make build

# Stage everything the scratch runtime needs, in the builder (which HAS a shell):
#   • ca-certificates → the CA bundle file for outbound TLS;
#   • busybox-static  → ONE static binary that we expose as /bin/{busybox,sh,wget}
#     applet symlinks. This is load-bearing: docker-compose.yml's healthcheck is
#     a CMD-SHELL form — `["CMD-SHELL", "wget -qO- http://localhost:9999/health
#     || exit 1"]` — which Docker runs via `/bin/sh -c "<string>"`. So scratch
#     must resolve BOTH a bare `/bin/sh` AND a bare `wget` on PATH, not just an
#     absolute `/bin/busybox wget`. busybox provides both applets, so the exact
#     compose contract keeps working byte-for-byte without touching compose.
#   • /stage/usr/local/bin/{auth,gotrue} → binary + symlink alias, so the scratch
#     COPY brings the link across (scratch can't `RUN ln -s`).
RUN apk add --no-cache ca-certificates busybox-static \
 && install -d /stage/usr/local/bin /stage/etc/ssl/certs /stage/bin \
 && cp /go/src/github.com/supabase/auth/auth /stage/usr/local/bin/auth \
 && ln -s auth /stage/usr/local/bin/gotrue \
 && cp /etc/ssl/certs/ca-certificates.crt /stage/etc/ssl/certs/ca-certificates.crt \
 && cp /bin/busybox.static /stage/bin/busybox \
 && ln -s busybox /stage/bin/sh \
 && ln -s busybox /stage/bin/wget

# ── Runtime ─────────────────────────────────────────────────────────────────
# SCRATCH: the static `auth` binary + the staged CA bundle, migrations, and a
# static busybox (see header). Non-root uid 1000 (upstream's `supabase` user),
# numeric because scratch has no /etc/passwd.
FROM scratch AS runtime

# Binary + `gotrue` alias symlink (staged together so the link resolves).
COPY --from=build /stage/usr/local/bin/ /usr/local/bin/
# CA bundle for outbound TLS (Postgres / SMTP / OAuth).
COPY --from=build /stage/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# Static busybox + its /bin/{sh,wget} applet symlinks → satisfies the compose
# CMD-SHELL healthcheck (`/bin/sh -c "wget …"`) byte-for-byte.
COPY --from=build /stage/bin/ /bin/

# Migrations shipped + pointed at, exactly like upstream — the binary auto-runs
# them on boot (root command = migrate then serve).
COPY --from=build /go/src/github.com/supabase/auth/migrations /usr/local/etc/auth/migrations/
ENV GOTRUE_DB_MIGRATIONS_PATH=/usr/local/etc/auth/migrations

EXPOSE 9999
# scratch has no /etc/passwd, so the non-root user must be a numeric uid:gid.
USER 1000:1000

# In-image healthcheck mirrors compose's CMD-SHELL contract exactly (bare `wget`
# resolved via the busybox applet); harmless if compose's own healthcheck
# overrides it.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD ["/bin/sh", "-c", "wget -qO- http://localhost:9999/health || exit 1"]

# No subcommand => `migrate` then `serve` on :9999 (reads GOTRUE_* env).
CMD ["auth"]
