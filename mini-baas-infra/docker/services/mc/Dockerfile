# syntax=docker/dockerfile:1
# File: docker/services/mc/Dockerfile
#
# Self-built MinIO Client (`mc`) — used by the `minio-iceberg-init` compose
# service to create the iceberg bucket. We download the upstream STATIC `mc`
# binary (a release artifact, NOT a ready-made image) from MinIO's official
# release CDN onto Alpine. Alpine is the only base we pull (42-Inception rule).
#
# The compose service overrides ENTRYPOINT with a `sh -c "…"` bootstrap loop
# (mc alias set / mc mb / mc anonymous set), so this image only needs `mc`,
# a POSIX shell, and CA certs on PATH. Tag matches the compose pin.

# ── builder: fetch + verify the static binary ────────────────────────────────
FROM alpine:3.21 AS build
ARG MC_RELEASE=RELEASE.2025-04-08T15-39-49Z
RUN apk add --no-cache wget \
 && wget -q -O /mc \
      "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.${MC_RELEASE}" \
 && chmod +x /mc \
 && /mc --version

# ── final: Alpine (busybox `sh` for the compose bootstrap) + CA certs ────────
FROM alpine:3.21
RUN apk add --no-cache ca-certificates \
 && adduser -D -u 1001 mc
COPY --from=build /mc /usr/bin/mc

USER 1001:1001
# A short-lived init container; compose supplies the full `sh -c "…"` entrypoint.
ENTRYPOINT ["mc"]
