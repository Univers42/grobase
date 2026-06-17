# syntax=docker/dockerfile:1
# File: docker/services/mc/Dockerfile
#
# Self-built MinIO Client (`mc`) — used by the `minio-iceberg-init` compose
# service to create the iceberg bucket. We download the upstream STATIC `mc`
# binary (a release artifact, NOT a ready-made image) from MinIO's official
# release CDN onto SCRATCH. The `mc` binary is fully statically linked (verified:
# `ldd` reports "Not a valid dynamic program"), so it runs on scratch directly —
# dropping the ~8 MB Alpine layer + its shell/apk attack surface. Tag matches
# the compose pin.
#
# Why scratch is safe here:
#   • static binary → no /lib, no loader needed at runtime;
#   • the compose service OVERRIDES the entrypoint with a `sh -c "until mc alias
#     set … ; do sleep 1; done; mc mb …; mc anonymous set …"` bootstrap, so the
#     image must provide a POSIX shell + `sleep`/`echo`. We ship ONE static
#     busybox exposed as /bin/{busybox,sh,sleep,echo} applet symlinks — that
#     satisfies the compose entrypoint byte-for-byte (same pattern as
#     docker/services/postgrest/Dockerfile, extended with the applets the loop
#     needs);
#   • mc connects to the in-network MinIO over PLAIN HTTP (http://minio:9000),
#     not TLS — but mc still loads its trust store for `mc` subcommands that
#     could touch TLS, so we copy the CA bundle file defensively (cheap, ~220 KB);
#   • mc writes its client config under $HOME/.mc; scratch has no /etc/passwd, so
#     we set HOME=/home/mc and pre-create /home/mc/.mc OWNED by uid 1001 (a bare
#     COPY of a dir does not preserve a 1777 mode, so we must COPY --chown the
#     home tree, and pre-make .mc so mc never has to mkdir at runtime), and run
#     as numeric USER 1001:1001 (no /etc/passwd on scratch).

# ── builder: fetch + verify the static binary + stage busybox/CA/home ────────
FROM alpine:3.21 AS build
ARG MC_RELEASE=RELEASE.2025-04-08T15-39-49Z
RUN apk add --no-cache wget ca-certificates busybox-static \
 && wget -q -O /mc \
      "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.${MC_RELEASE}" \
 && chmod +x /mc \
 && /mc --version
# Stage the runtime layout the scratch image needs (builder has a shell):
#   /bin/{busybox,sh,sleep,echo} applet symlinks, the CA bundle, and a writable
#   home with .mc pre-created (chowned to 1001 by the COPY below).
RUN install -d /stage/bin /stage/etc/ssl/certs \
 && cp /bin/busybox.static /stage/bin/busybox \
 && ln -s busybox /stage/bin/sh \
 && ln -s busybox /stage/bin/sleep \
 && ln -s busybox /stage/bin/echo \
 && cp /etc/ssl/certs/ca-certificates.crt /stage/etc/ssl/certs/ca-certificates.crt \
 && install -d /stage-home/.mc

# ── final: SCRATCH + static busybox (sh/sleep/echo) + CA certs + writable home ─
FROM scratch
COPY --from=build /mc /usr/bin/mc
COPY --from=build /stage/bin/ /bin/
COPY --from=build /stage/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# Home tree owned by uid 1001 so mc can write $HOME/.mc/config.json at runtime.
COPY --from=build --chown=1001:1001 /stage-home /home/mc
# mc keeps its config under $HOME/.mc.
ENV HOME=/home/mc
# scratch has no /etc/passwd, so the non-root user must be a numeric uid:gid.
USER 1001:1001
# A short-lived init container; compose supplies the full `sh -c "…"` entrypoint.
ENTRYPOINT ["mc"]
