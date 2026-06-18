# syntax=docker/dockerfile:1
# File: docker/services/minio/Dockerfile
#
# Self-built MinIO: we download the upstream STATIC `minio` server binary
# (a release artifact, NOT a ready-made image) from MinIO's official release
# CDN and drop it onto Alpine. Alpine is the only base we pull (allowed by the
# 42-Inception rule). The `server /data --console-address ":9001"` command and
# the curl healthcheck both come from docker-compose.yml.
#
# Tag matches the compose pin (RELEASE.2025-09-07T16-13-09Z). The compose image
# used the `-cpuv1` baseline build; the plain release is functionally identical
# (same code, wider CPU baseline) and runs on any amd64.

# ── builder: fetch + verify the static binary ────────────────────────────────
FROM alpine:3.21 AS build
ARG MINIO_RELEASE=RELEASE.2025-09-07T16-13-09Z
RUN apk add --no-cache wget \
 && wget -q -O /minio \
      "https://dl.min.io/server/minio/release/linux-amd64/archive/minio.${MINIO_RELEASE}" \
 && chmod +x /minio \
 && /minio --version

# ── final: Alpine + ca-certs + curl (for the compose healthcheck) ────────────
FROM alpine:3.21
RUN apk add --no-cache ca-certificates curl \
 && addgroup -g 1001 minio \
 && adduser -D -u 1001 -G minio minio \
 && install -d -o minio -g minio /data
COPY --from=build /minio /usr/bin/minio

EXPOSE 9000 9001
USER 1001:1001
WORKDIR /data

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:9000/minio/health/live >/dev/null || exit 1

# `minio` is the ENTRYPOINT, so compose's `command: server /data --console-address ":9001"`
# is appended as its args -> `minio server /data ...` (the official image's contract).
ENTRYPOINT ["minio"]
